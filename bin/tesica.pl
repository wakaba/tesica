use strict;
use warnings;
use Path::Tiny;
use Time::HiRes qw(time);
use ArrayBuffer;
use DataView;
use Promise;
use Promised::Flow;
use Promised::File;
use Promised::Command;
use JSON::PS;

sub _files ($$$$$);
sub _files ($$$$$) {
  my ($base, $names, $name_pattern, $next_name_pattern, $files) = @_;
  return promised_for {
    my $name = $_[0];
    my $path = path ($name)->absolute ($base);
    my $file = Promised::File->new_from_path ($path);
    return $file->is_file->then (sub {
      if ($_[0]) {
        push @$files, $path if $name =~ /$name_pattern/;
      } else {
        return $file->is_directory->then (sub {
          if ($_[0]) {
            return $file->get_child_names->then (sub {
              return _files $path, [sort { $a cmp $b } @{$_[0]}], $next_name_pattern, $next_name_pattern, $files;
            });
          } else {
            die "|$path| is not a test script\n";
          }
        });
      }
    });
  } $names;
} # _files

sub expand_files ($) {
  my $rule = $_[0];

  unless (defined $rule->{files} and
          ref $rule->{files} eq 'ARRAY') {
    $rule->{files} = ['t'];
  }

  my $files = [];
  return _files ($rule->{base_dir}, $rule->{files}, qr/./, qr/\.t\z/, $files)->then (sub {
    return $files;
  });
} # expand_files

sub process_files ($$$) {
  my ($base_dir_path, $file_paths, $result) = @_;

  return promised_for {
    my $path = shift;
    my $file_name = $path->relative ($base_dir_path);

    # XXX
    print STDERR "$file_name...";

    my $cmd = Promised::Command->new ([ # XXX
      'perl',
      $path,
    ]);

    my $fr = $result->{file_results}->{$file_name} = {
      result => {ok => 0},
      times => {start => time},
    };
    my $escaped_name = $file_name;
    $escaped_name =~ s{([^A-Za-z0-9])}{sprintf '_%02X', ord $1}ge;
    my $output_path = $base_dir_path->child ('local/test/files')
        ->child ($escaped_name . '.txt');
    $fr->{output_file} = $output_path->relative ($base_dir_path);
    my $output_ws = Promised::File->new_from_path ($output_path)->write_bytes;
    my $output_w = $output_ws->get_writer;
    my $so_rs = $cmd->get_stdout_stream;
    my $so_r = $so_rs->get_reader ('byob');
    promised_until {
      return $so_r->read (DataView->new (ArrayBuffer->new (1024)))->then (sub {
        return 'done' if $_[0]->{done};
        print STDERR ".";
        return $output_w->write ($_[0]->{value})->then (sub {
          return not 'done';
        });
      });
    };
    my $se_rs = $cmd->get_stderr_stream;
    my $se_r = $se_rs->get_reader ('byob');
    promised_until {
      return $se_r->read (DataView->new (ArrayBuffer->new (1024)))->then (sub {
        return 'done' if $_[0]->{done};
        print STDERR ".";
        return $output_w->write ($_[0]->{value})->then (sub {
          return not 'done';
        });
      });
    };
    # XXX stdout/stderr line boundaries
    return $cmd->run->then (sub {
      return $cmd->wait;
    })->then (sub {
      my $cr = $_[0];
      $fr->{times}->{end} = time;
      $fr->{result}->{exit_code} = $cr->exit_code;
      die $cr unless $cr->exit_code == 0;
      $fr->{result}->{ok} = 1;
      $result->{result}->{pass}++;
      warn " PASS\n";
    })->catch (sub {
      my $e = $_[0];
      $fr->{error}->{message} = ''.$e;
      warn " FAIL\n";
      $result->{result}->{fail}++;
    })->finally (sub {
      return $output_w->close;
    });
  } $file_paths;
} # process_files

sub main () {
  my $rule;
  my $result = {result => {exit_code => 1, pass => 0, fail => 0},
                times => {start => time},
                file_results => {}};
  my $base_dir_path;
  return Promise->resolve->then (sub {
    $rule = {
      type => 'perl',
      result_json_file => 'local/test/result.json',
    };
    $rule->{base_dir} = '.' unless defined $rule->{base_dir};
    $base_dir_path = path ($rule->{base_dir})->absolute;
    $result->{rule}->{base_dir} = '' . $base_dir_path;
    $result->{rule}->{type} = $rule->{type};
    my $result_json_path = path ($rule->{result_json_file})->absolute ($base_dir_path);
    $result->{result}->{json_file} = $result_json_path->relative ($base_dir_path);

    return expand_files $rule;
  })->then (sub {
    my $files = $_[0];
    $result->{files} = [map {
      $_->relative ($base_dir_path);
    } @$files];
    return process_files $base_dir_path, $files => $result;
  })->then (sub {
    if ($result->{result}->{fail}) {
      #$result->{result}->{exit_code} = 1;
    } else {
      $result->{result}->{exit_code} = 0;
      $result->{result}->{ok} = 1;
    }
  })->catch (sub {
    my $error = $_[0];
    $result->{result}->{error} = '' . $error;
    $result->{result}->{exit_code} = 1;
    warn "ERROR: $error\n";
  })->then (sub {
    $result->{times}->{end} = time;
    my $result_json_file = Promised::File->new_from_path
        ($result->{result}->{json_file});
    return $result_json_file->write_byte_string (perl2json_bytes $result);
  })->then (sub {
    return $result;
  });
} # main

my $result = main ()->to_cv->recv; # or die
exit $result->{result}->{exit_code};

=head1 NAME

tesica

=head1 SYNOPSIS

  $ tesica

=head1 TESTING

The B<base directory> is the current directory.

A B<test script> is a file containing a set of tests.  The files whose
name ends by C<.t> contained directly or indirectly, without following
symlinks, in the C<t> directory under the base directory are the test
scripts to be used.

=head1 RESULT FILE

The result is written to the C<local/test/result.json>, which is a
JSON file of a JSON object with following name/value pairs:

=over 4

=item rule

A JSON object with following name/value pairs:

=over 4

=item type

A string C<perl>.

=item base_dir : String

The absolute path of the base directory.

=back

=item files : Array<Path>

A JSON array of the paths of the test scripts.

=item file_results : Object<Path, Object>

A JSON object whose names are the paths of the test scripts and values
are corresponding results, with following name/value pairs:

=over 4

=item times : Times

The timestamps of the process of the test script.

=item result : Result

The result of the process of the test script, referred to as "file
result".

=back

=item result : Result

The result of the entire test, referred to as "global result".

=back

=head2 Data types

The data types used to describe result file content are as follows:

=over 4

=item Array<I<T>>

A JSON array whose members are of I<T>.

=item Boolean

A boolean value.  False is represented by one of: a JSON number 0, an
empty String, a JSON false value, a JSON null value, or omission of
the name/value pair if the context is the value of a name/value pair
of an Object.  True is represented by a non-false value.

=item Integer

A JSON number representing an integer value.

=item Object

A JSON object.

=item Object<I<T>, I<U>>

A JSON object whose names are of I<T> and values are of I<U>.

=item Path

A String representing a Unix-style file or directory path, which can
be resolved relative to the |rule|'s |base_dir|.

=item String

A JSON string or a number representing its string value.

=item Times

An Object representing timestamps related to a process, with following
name/value pairs:

=over 4

=item end : Timestamp

The end time of the process.

=item start : Timestamp

The start time of the process.

=back

=item Timestamp

A JSON number representing a Unix time.

=item Result

An Object representing a result of the process, with following
name/value pairs:

=over 4

=item exit_code : Integer

The exit code of the process.  The exit code of the Unix process, if
the process is a Unix process.  E.g. zero if there is no problem
detected.

=item fail : Integer?

The number of the failed tests within the process, if known.

=item json_file : Path (global result only)

The path to the result JSON file.

=item ok : Boolean

Whether the process is success or not.

=item output_file : Path (file result only)

The path to the output file, which contains standard output and
standard error output of the test script.  The output file is stored
under the C<local/test/files> directory within the base directory.

=item pass : Integer?

The number of the passed tests within the process, if known.

=back


=back

=head1 AUTHOR

Wakaba <wakaba@suikawiki.org>.

=head1 LICENSE

Copyright 2018-2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
