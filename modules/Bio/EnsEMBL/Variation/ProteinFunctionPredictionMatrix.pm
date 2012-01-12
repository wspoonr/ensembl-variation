=head1 LICENSE

 Copyright (c) 1999-2012 The European Bioinformatics Institute and
 Genome Research Limited.  All rights reserved.

 This software is distributed under a modified Apache license.
 For license details, please see

   http://www.ensembl.org/info/about/code_licence.html

=head1 CONTACT

 Please email comments or questions to the public Ensembl
 developers list at <dev@ensembl.org>.

 Questions may also be sent to the Ensembl help desk at
 <helpdesk@ensembl.org>.

=cut

=head1 NAME

Bio::EnsEMBL::Variation::ProteinFunctionPredictionMatrix

=head1 SYNOPSIS

  # create a new matrix for polyphen predictions

  my $orig_pfpm = Bio::EnsEMBL::Variation::ProteinFunctionPredictionMatrix->new(
      -analysis       => 'polyphen',
      -peptide_length => 134,
  );

  # add some predictions

  $orig_pfpm->add_prediction(1, 'A', 'probably damaging', 0.967);
  $orig_pfpm->add_prediction(2, 'C', 'benign', 0.09);

  # serialize the matrix to a compressed binary string

  my $binary_string = $pfpm->serialize;

  # store the string somewhere, fetch it later, and then create a new matrix using it

  my $new_pfpm = Bio::EnsEMBL::Variation::ProteinFunctionPredictionMatrix->new(
      -analysis   => 'polyphen',
      -matrix     => $binary_string
  );

  # retrieve predictions

  my ($prediction, $score) = $new_pfpm->get_prediction(2, 'C');

  print "A mutation to 'C' at position 2 is predicted to be $prediction\n";

=head1 DESCRIPTION

This module defines a class representing a matrix of protein
function predictions, and provides method to access and set
predictions for a given position and amino acid, and also to
serialize the matrix for storage in a database, and deserialize
a matrix from the compressed format into a perl hash.

=cut

package Bio::EnsEMBL::Variation::ProteinFunctionPredictionMatrix;

use strict;
use warnings;

use POSIX qw(ceil);
use List::Util qw(max);
use Compress::Zlib;

use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::EnsEMBL::Utils::Argument qw(rearrange);

use base qw(Exporter);

our @EXPORT_OK = qw($AA_LOOKUP @ALL_AAS);

my $DEBUG = 0;

# user-defined constants

# a header which lets us identify prediction matrices and
# to check if they may have been corrupted

our $HEADER     = 'VEP';

# the format we use when 'pack'ing our predictions

my $PACK_FORMAT = 'v';

# a hash mapping qualitative predictions to numerical values
# for all the analyses we use

my $PREDICTION_TO_VAL = {
    polyphen => {
        'probably damaging' => 0,
        'possibly damaging' => 1,
        'benign'            => 2,
        'unknown'           => 3,
    },

    sift => {
        'tolerated'     => 0,
        'deleterious'   => 1,
    },
};

# all valid amino acids

our @ALL_AAS = qw(A C D E F G H I K L M N P Q R S T V W Y);

# we use a short with all bits set to represent the lack of a prediction in 
# an (uncompressed) prediction matrix, we will never observe this value
# as a real prediction even if we set all the (6) prediction bits because we 
# limit the max score to 1000 so the 10 score bits will never all be set

our $NO_PREDICTION = pack($PACK_FORMAT, 0xFFFF);

# constants derived from the the user-defined constants

# the maximum number of distinct qualitative predictions used by any tool

my $MAX_NUM_PREDS = max( map { scalar keys %$_ } values %$PREDICTION_TO_VAL ); 

my $BYTES_PER_PREDICTION = 2;

# the number of bits used to encode the qualitative prediction

my $NUM_PRED_BITS = ceil( log($MAX_NUM_PREDS) / log(2) );

throw("Cannot represent more than ".(2**6-1)." predictions") if $NUM_PRED_BITS > 6;

# a hash mapping back from a numerical value to a qualitative prediction

my $VAL_TO_PREDICTION = {
    map {
        my $tool = $_; 
        $tool => {
            map {
                $PREDICTION_TO_VAL->{$tool}->{$_} => $_ 
            } keys %{ $PREDICTION_TO_VAL->{$tool} }
        }
    } keys %$PREDICTION_TO_VAL
};

# a hash from amino acid single letter code to a numerical value

our $AA_LOOKUP = { map {$ALL_AAS[$_] => $_} 0 .. $#ALL_AAS };

# the number of valid amino acids

our $NUM_AAS = scalar(@ALL_AAS);

=head2 new

  Arg [-ANALYSIS] : 
    The name of the analysis tool that made these predictions,
    currently must be one of 'sift' or 'polyphen'

  Arg [-MATRIX] :
    A gzip compressed binary string encoding the predictions,
    typically created using this class and fetched from the 
    variation database (optional)

  Arg [-PEPTIDE_LENGTH] :
    The length of the associated peptide, only required if
    you want to serialize this matrix (optional)

  Description: Constructs a new ProteinFunctionPredictionMatrix object
  Returntype : A new Bio::EnsEMBL::Variation::ProteinFunctionPredictionMatrix instance 
  Exceptions : throws unless ANALYSIS is supplied and recognised
  Status     : At Risk

=cut 

sub new {
    my $class = shift;
    
    my (
        $analysis,
        $matrix,
        $peptide_length,
    ) = rearrange([qw(
            ANALYSIS
            MATRIX
            PEPTIDE_LENGTH
        )], @_);
    
    throw("analysis argument required") unless defined $analysis;
    
    throw("Unrecognised analysis '$analysis'") 
        unless defined $PREDICTION_TO_VAL->{$analysis};

    my $self = bless {
        analysis        => $analysis,
        matrix          => $matrix,
        peptide_length  => $peptide_length,
    }, $class;

    $self->{matrix_compressed} = defined $matrix ? 1 : 0;

    return $self;
}

=head2 analysis

  Arg[1]      : string $analysis - the name of the analysis tool (optional)
  Description : Get/set the analysis name
  Returntype  : string
  Exceptions  : throws if the name is not recognised 
  Status      : At Risk
  
=cut

sub analysis {
    my ($self, $analysis) = @_;
    
    if ($analysis) {
        throw("Unrecognised analysis '$analysis'") 
            unless defined $PREDICTION_TO_VAL->{$analysis};

        $self->{analysis} = $analysis;
    }

    return $self->{analysis};
}

=head2 peptide_length

  Arg[1]      : int $peptide_length - the length of the peptide (optional)
  Description : Get/set the length of the peptide - required when you want to
                serialize a matrix, as we need to know how many rows the matrix has
  Returntype  : int
  Exceptions  : none 
  Status      : At Risk
  
=cut

sub peptide_length {
    my ($self, $peptide_length) = @_;
    $self->{peptide_length} = $peptide_length if defined $peptide_length;
    return $self->{peptide_length};
}

=head2 get_prediction

  Arg[1]      : int $pos - the desired position
  Arg[2]      : string $aa - the mutant amino acid
  Description : get the prediction and score for the given position and amino acid
  Returntype  : a list containing 2 values, the prediction and the score
  Exceptions  : throws if either the position or amino acid are invalid 
  Status      : At Risk
  
=cut

sub get_prediction {
    my ($self, $pos, $aa) = @_;

    # if we have it in our uncompressed hash then just return it

    if (defined $self->{preds}->{$pos}->{$aa}) {
        return @{ $self->{preds}->{$pos}->{$aa} };
    }

    # otherwise we look in the serialized matrix string

    return $self->prediction_from_matrix($pos, $aa);
}

=head2 add_prediction

  Arg[1]      : int $pos - the peptide position
  Arg[2]      : string $aa - the mutant amino acid
  Arg[3]      : string $prediction - the prediction to store
  Arg[4]      : float $score - the score to store
  Description : add a prediction to the matrix for the specified position and amino acid,
                note that this just adds the prediction to a perl hash. If you want to
                encode the matrix in the binary format you should call serialize on the 
                matrix object after you have added all the predictions.
  Exceptions  : none
  Status      : At Risk
  
=cut

sub add_prediction {
    my ($self, $pos, $aa, $prediction, $score) = @_;

    $self->{preds}->{$pos}->{$aa} = [$prediction, $score];
}

=head2 serialize

  Arg[1]      : int $peptide_length - the length of the associated peptide (optional)
  Description : serialize the matrix into a compressed binary format suitable for
                storage in a database, file etc. The same string can later be used
                to create a new matrix object and the predictions can be retrieved
  Exceptions  : throws if the peptide length has not been specified
  Status      : At Risk
  
=cut

sub serialize {
    my ($self, $peptide_length) = @_;

    $self->{peptide_length} = $peptide_length if defined $peptide_length;

    throw("peptide_length required to serialize predictions") 
        unless defined $self->{peptide_length};

    # convert predictions to the binary format, and concatenate them all 
    # together in the correct order, inserting our dummy $NO_PREDICTION
    # value to fill in any gaps

    if ($self->{preds}) {

        $self->{matrix_compressed} = 0;

        $self->{matrix} = $HEADER;

        for my $pos (1 .. $self->{peptide_length}) {
        
            for my $aa (@ALL_AAS) {
                
                my $short;

                if ($self->{preds}->{$pos}->{$aa}) {
                    my ($prediction, $score) = @{ $self->{preds}->{$pos}->{$aa} };
                
                    $short = $self->prediction_to_short($prediction, $score);
                }

                $self->{matrix} .= defined $short ? $short : $NO_PREDICTION;
            }
        }

        # delete the hash copy, so things don't get out of sync

        $self->{preds} = undef;
    }
    else {
        warning("There don't seem to be any predictions in the matrix to serialize!");
    }

    # and return the compressed string for storage

    return $self->compress_matrix;
}

=head2 deserialize

  Arg [1]     : coderef $coderef - an anonymous subroutine that will be called 
                as each prediction is decoded in order. The subroutine will be 
                called with 4 arguments: the peptide position, the amino acid, 
                the prediction and the score. This can be used, for example to 
                dump out the prediction matrix to a file. (optional)
  Description : deserialize a binary formatted matrix into a perl hash reference
                containing all the uncompressed predictions. This hash has an 
                entry for each position in the peptide, which is itself a hashref
                with an entry for each possible alternate amino acid which is a 
                listref containing the prediction and score. For example, to retrieve
                the prediction for a substitution of 'C' at position 23 from this
                data structure, you could use code like:

                my $prediction_hash = $pfpm->deserialize;
                my ($prediction, $score) = @{ $prediction_hash->{23}->{'C'} };

                Note that if you don't explicitly deserialize a matrix this
                class will keep it in the memory-efficient encoded format, and
                you can access individual predictions with the get_prediction()
                method. You should only use this method if you want to decode
                all predictions (for example to perform some large-scale 
                analysis, or to reformat the predictions somehow)

  Returntype  : hashref containing decoded predictions
  Exceptions  : throws if the binary matrix isn't in the expected format
  Status      : At Risk
  
=cut

sub deserialize {
    my ($self, $coderef) = @_;

    if ($self->{matrix_compressed}) {
        $self->expand_matrix;
    }

    throw("Matrix looks corrupted") unless $self->header_ok;

    # we can work out the length of the peptide by counting the rows in the matrix

    my $length = ((length($self->{matrix}) - length($HEADER)) / $BYTES_PER_PREDICTION) / $NUM_AAS;

    for my $pos (1 .. $length) {
        
        for my $aa (@ALL_AAS) {

            # we call prediction_from_short directly to avoid doing all the
            # checks performed in prediction_from_string

            my ($prediction, $score) = $self->prediction_from_short(substr($self->{matrix}, $self->compute_offset($pos, $aa), $BYTES_PER_PREDICTION));

            $self->{preds}->{$pos}->{$aa} = [$prediction, $score];

            if ($coderef) {
                $coderef->($pos, $aa, $prediction, $score);
            }
        }
    }
    
    return $self->{preds};
}

=head2 prediction_to_short

  Arg[1]      : string $pred - one of the possible qualitative predictions of the tool 
  Arg[2]      : float $prob - the prediction score (with 3 d.p.s of precision)
  Description : converts a prediction and corresponding score into a 2-byte short value
  Returntype  : the packed short value
  Exceptions  : throws if the prediction argument is invalid 
  Status      : At Risk
  
=cut

sub prediction_to_short {
    my ($self, $pred, $prob) = @_;

    # we only store 3 d.p. so multiply by 1000 to turn our
    # probability into a number between 0 and 1000. 
    # 2^10 == 1024 so we need 10 bits of our short to store 
    # this value
    
    my $val = $prob * 1000;

    # we store the prediction in the top $NUM_PRED_BITS bits
    # so look up the numerical value for the prediction, 
    # shift this $NUM_PRED_BITS bits to the left and then set
    # the appropriate bits of our short value
    
    $pred = lc($pred);
    
    my $pred_val = $PREDICTION_TO_VAL->{$self->{analysis}}->{$pred};

    throw("No value defined for prediction: '$pred'?")
        unless defined $pred_val;

    $val |= ($pred_val << (16 - $NUM_PRED_BITS));

    printf("p2s: $pred ($prob) => 0x%04x\n", $val) if $DEBUG;
    
    $val = pack $PACK_FORMAT, $val;

    return $val;
}

=head2 prediction_from_short

  Arg[1]      : string $pred - the packed short value 
  Description : converts a 2-byte short value back into a prediction and a score
  Exceptions  : none
  Returntype  : a list containing 2 values, the prediction and the score
  Status      : At Risk
  
=cut

sub prediction_from_short {
    my ($self, $val) = @_;

    # check it isn't our special null prediction

    if ($val eq $NO_PREDICTION) {
        print "no pred\n" if $DEBUG;
        return undef;
    }

    # unpack the value as a short

    $val = unpack $PACK_FORMAT, $val;

    # shift the prediction bits down and look up the prediction string

    my $pred = $VAL_TO_PREDICTION->{$self->{analysis}}->{$val >> (16 - $NUM_PRED_BITS)};

    # mask off the top 6 bits reserved for the prediction and convert back to a 3 d.p. float

    my $prob = ($val & (2**10 - 1)) / 1000;

    printf("pfs: 0x%04x => $pred ($prob)\n", $val) if $DEBUG;

    return ($pred, $prob);
}

=head2 compress_matrix

  Description : compresses a prediction matrix with gzip
  Returntype  : the compressed matrix
  Exceptions  : throws if the matrix is an unexpected length, or if the compression fails
  Status      : At Risk
  
=cut

sub compress_matrix {
    my ($self) = @_;

    my $matrix = $self->{matrix};

    return undef unless $matrix;

    return $matrix if $self->{matrix_compressed};
    
    # prepend a header, so we can tell if our matrix has been mangled, or
    # is compressed etc.
    
    unless ($self->header_ok) {
        $matrix = $HEADER.$matrix;
    }

    throw("Prediction matrix is an unexpected length")
         unless ( (length($matrix) - length($HEADER)) % $NUM_AAS) == 0;

    $self->{matrix} = Compress::Zlib::memGzip($matrix) or throw("Failed to gzip: $gzerrno");

    $self->{matrix_compressed} = 1;

    return $self->{matrix};
}

=head2 header_ok

  Description : checks if the binary matrix has the expected header
  Returntype  : boolean
  Exceptions  : none
  Status      : At Risk
  
=cut

sub header_ok {
    my ($self) = @_;
    return undef unless ($self->{matrix} && !$self->{matrix_compressed});
    return substr($self->{matrix},0,length($HEADER)) eq $HEADER;
}

=head2 expand_matrix

  Description : uncompresses a compressed prediction matrix
  Returntype  : the uncompressed binary matrix string
  Exceptions  : throws if the header is incorrect, or if the decompression fails
  Status      : At Risk
  
=cut

sub expand_matrix {
    my ($self) = @_;

    return undef unless $self->{matrix};

    return $self->{matrix} unless $self->{matrix_compressed};

    $self->{matrix} = Compress::Zlib::memGunzip($self->{matrix})
        or throw("Failed to gunzip: $gzerrno");

    $self->{matrix_compressed} = 0;

    throw("Malformed prediction matrix") unless $self->header_ok;
    
    return $self->{matrix};
}

=head2 compute_offset

  Arg[1]      : int $pos - the desired position in the peptide 
  Arg[2]      : string $aa - the desired mutant amino acid
  Description : computes the correct offset into a prediction matrix for a given
                peptide position and mutant amino acid
  Returntype  : the integer offset
  Exceptions  : none
  Status      : At Risk
  
=cut

sub compute_offset {
    my ($self, $pos, $aa) = @_;

    my $offset = length($HEADER) + ( ( (($pos-1) * $NUM_AAS) + $AA_LOOKUP->{$aa} ) * $BYTES_PER_PREDICTION );

    return $offset;
}

=head2 prediction_from_matrix

  Arg[1]      : int $pos - the desired position in the peptide 
  Arg[2]      : string $aa - the desired mutant amino acid
  Description : returns the prediction and score for the requested 
                position and mutant amino acid in the matrix
  Returntype  : a list containing 2 values, the prediction and the score
  Exceptions  : throws if either the position or amino acid are invalid, 
                or if the prediction matrix looks to be malformed
  Status      : At Risk
  
=cut

sub prediction_from_matrix {
    my ($self, $pos, $aa) = @_;

    if ($self->{matrix_compressed}) {
        # the matrix is still compressed so we try to uncompress it, 
        $self->expand_matrix;
    }

    $aa = uc($aa) if defined $aa;

    throw("Invalid position: $pos") unless (defined $pos && $pos > 0);
    
    throw("Invalid amino acid: $aa") unless (defined $aa && defined $AA_LOOKUP->{$aa});

    # compute our offset into the prediction matrix

    my $offset = $self->compute_offset($pos, $aa);
    
    print "offset: $offset\n" if $DEBUG;
    
    if ($offset + 1 > length($self->{matrix})) {
        warning("Offset outside of prediction matrix for position $pos and amino acid $aa?");
        return undef;
    }
    
    my $pred = substr($self->{matrix}, $offset, $BYTES_PER_PREDICTION);

    return $self->prediction_from_short($pred);
}

1;

