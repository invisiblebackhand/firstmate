use strict;
use warnings;
use JSON::PP;

# Lavish emits flat prompt rows as TOON CSV, and switches the entire block to
# expanded mappings when one row has a nested target. Return the same hashes
# for both shapes so presentation and keyed-answer intake share one verdict.
sub lavish_rows {
  my ($path, $allow_empty) = @_;
  open my $fh, '<:encoding(UTF-8)', $path or die "cannot read Lavish result: $!\n";
  my @lines = <$fh>;
  close $fh or die "cannot read Lavish result: $!\n";

  my ($header, $want, $shape, @fields);
  for my $i (0 .. $#lines) {
    my $line = $lines[$i];
    if ($line =~ /^(prompts|feedback)\[(\d+)\]\{([^}]*)\}:\s*$/) {
      ($header, $want, $shape, @fields) = ($i, $2, 'table', split /,/, $3);
      die "cannot read Lavish table fields: empty field list\n" unless @fields;
      last;
    }
    if ($line =~ /^(prompts|feedback)\[(\d+)\]:\s*$/) {
      ($header, $want, $shape) = ($i, $2, 'expanded');
      last;
    }
    die "cannot read Lavish content block header: $line"
      if $line =~ /^(?:prompts|feedback|[A-Za-z][A-Za-z0-9_-]*\[)/;
  }
  if (!defined $header) {
    die "cannot read Lavish content block: no recognized header\n" unless $allow_empty;
    return (0, [], 0);
  }

  my @rows;
  my $malformed = 0;
  for my $i ($header + 1 .. $#lines) {
    my $line = $lines[$i];
    last unless $line =~ /^\s/;
    chomp $line;
    if ($shape eq 'table') {
      die "cannot read Lavish table items: more than $want rows\n"
        if @rows + $malformed >= $want;
      $line =~ s/^\s+//;
      my @vals;
      while (length $line) {
        if ($line =~ s/^"((?:[^"\\]|\\.)*)"//) {
          push @vals, $1;
        } else {
          $line =~ s/^([^,]*)//;
          push @vals, $1;
        }
        last unless $line =~ s/^,//;
      }
      if (@vals > @fields) {
        my ($preserve) = grep { $fields[$_] eq 'prompt' } 0 .. $#fields;
        ($preserve) = grep { $fields[$_] eq 'text' } 0 .. $#fields unless defined $preserve;
        if (defined $preserve) {
          my @parts = splice @vals, $preserve, @vals - @fields + 1;
          splice @vals, $preserve, 0, join(',', @parts);
        }
      }
      if (@vals != @fields) {
        $malformed++;
        next;
      }
      s/\\(.)/$1 eq 'n' ? "\n" : $1 eq 't' ? "\t" : $1 eq 'r' ? "\r" : $1/ge for @vals;
      my %row;
      $row{$fields[$_]} = $vals[$_] for 0 .. $#fields;
      push @rows, \%row;
      next;
    }

    if ($line =~ /^  - ([A-Za-z][A-Za-z0-9]*):\s*(.*)$/) {
      die "cannot read Lavish expanded item: too many rows\n" if @rows >= $want;
      push @rows, {};
      my ($key, $value) = ($1, $2);
      $rows[-1]{$key} = lavish_scalar($value);
    } elsif ($line =~ /^    ([A-Za-z][A-Za-z0-9]*):\s*(.*)$/) {
      die "cannot read Lavish expanded item: field before item\n" unless @rows;
      my ($key, $value) = ($1, $2);
      if ($key eq 'target') {
        die "cannot read Lavish expanded target: expected mapping\n" if length $value;
        $rows[-1]{target} = {};
      } else {
        die "cannot read Lavish expanded field $key: expected scalar\n" unless length $value;
        $rows[-1]{$key} = lavish_scalar($value);
      }
    } elsif ($line =~ /^      ([A-Za-z][A-Za-z0-9]*):\s*(.*)$/) {
      die "cannot read Lavish expanded target: field outside target\n"
        unless @rows && ref($rows[-1]{target}) eq 'HASH';
      my ($key, $value) = ($1, $2);
      die "cannot read Lavish expanded target field $key: expected scalar\n" unless length $value;
      $rows[-1]{target}{$key} = lavish_scalar($value);
    } else {
      die "cannot read Lavish expanded item line: $line\n";
    }
  }
  if ($shape eq 'expanded') {
    die "cannot read Lavish expanded items: declared $want, found " . scalar(@rows) . "\n"
      unless @rows == $want;
    for my $row (@rows) {
      for my $field (qw(uid prompt selector tag text)) {
        die "cannot read Lavish expanded item: missing $field\n" unless exists $row->{$field};
      }
    }
  }
  return ($want, \@rows, $malformed);
}

sub lavish_scalar {
  my ($value) = @_;
  return $value unless $value =~ /^"/;
  my $decoded = eval { JSON::PP->new->utf8(0)->decode($value) };
  die "cannot read Lavish expanded quoted scalar: $value\n" if $@ || ref($decoded);
  return $decoded;
}

1;
