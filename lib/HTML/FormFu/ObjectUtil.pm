package HTML::FormFu::ObjectUtil;

use strict;
use warnings;
use Exporter qw/ import /;

use HTML::FormFu::Util qw/ _parse_args require_class _get_elements /;
use Config::Any;
use Scalar::Util qw/ refaddr weaken /;
use Storable qw/ dclone /;
use Carp qw/ croak /;

our @EXPORT_OK = qw/  
    _render_class _coerce populate
    _require_constraint
    _single_element 
    deflator get_fields get_field get_elements get_element
    get_all_elements get_errors get_error delete_errors
    load_config_file form insert_before insert_after clone name stash /;

sub _single_element {
    my ( $self, $element ) = @_;
    my @elements;
    
    if ( ref $element eq 'HASH' ) {
        push @elements, $element;
    }
    elsif ( !ref $element ) {
        push @elements, { type => $element };
    }
    else {
        croak 'invalid args';
    }

    my @return;

    for (@elements) {
        my $e = _require_element( $self, $_ );
        push @return, $e;
        
        if ( $self->can('auto_fieldset') 
             && $self->auto_fieldset 
             && $e->element_type ne 'fieldset' )
        {
            my ($target) = reverse @{ $self->get_elements({ type => 'fieldset' }) };
            
            push @{ $target->_elements }, $e;
        }
        else {
            push @{ $self->_elements }, $e;
        }
    }
    
    return @return;
}

sub _require_element {
    my ( $self, $arg ) = @_;

    $arg->{type} = 'text' if !exists $arg->{type};

    my $type = delete $arg->{type};
    my $class = $type;
    if ( not $class =~ s/^\+// ) {
        $class = "HTML::FormFu::Element::$class";
    }

    $type =~ s/^\+//;

    require_class($class);

    my $element = $class->new( {
            element_type    => $type,
            parent          => $self,
        } );

    weaken( $element->{parent} );

    if ( $element->can('element_defaults') ) {
        $element->element_defaults( dclone $self->element_defaults );
    }

    if ( exists $self->element_defaults->{ $type } ) {
        %$arg = ( %{ $self->element_defaults->{$type} }, %$arg );
    }

#    for (qw/ render_class_prefix render_method /)
#    {
#        $arg->{$_} = $self->$_ if !exists $arg->{$_};
#    }
#
#    $arg->{render_class_args} = dclone $self->render_class_args
#        if !exists $arg->{render_class_args};

    populate( $element, $arg );

    return $element;
}

sub get_elements {
    my $self = shift;
    my %args = _parse_args(@_);

    my @elements = @{ $self->_elements };

    return _get_elements( \%args, \@elements );
}

sub get_element {
    my $self = shift;

    my $e = $self->get_elements(@_);

    return @$e ? $e->[0] : ();
}

sub get_all_elements {
    my $self = shift;
    my %args = _parse_args(@_);

    my @e = map { $_, @{ $_->get_all_elements } } @{ $self->_elements };

    return _get_elements( \%args, \@e );
}

sub get_fields {
    my $self = shift;
    my %args = _parse_args(@_);

    my @e = map { $_->is_field ? $_ : @{ $_->get_fields } } @{ $self->_elements };

    return _get_elements( \%args, \@e );
}

sub get_field {
    my $self = shift;

    my $f = $self->get_fields(@_);

    return @$f ? $f->[0] : ();
}

sub _require_constraint {
    my ( $self, $type, $arg ) = @_;

    croak 'required arguments: $self, $type, \%options' if @_ != 3;

    eval { my %x = %$arg };
    croak "options argument must be hash-ref" if $@;

    my $abs = $type =~ s/^\+//;
    my $not = 0;

    if ( $type =~ /^Not_(\w+)$/i ) {
        $type = $1;
        $not  = 1;
    }

    my $class = $type;

    if ( !$abs ) {
        $class = "HTML::FormFu::Constraint::$class";
    }
    
    $type =~ s/^\+//;

    require_class($class);

    my $constraint = $class->new( {
            constraint_type => $type,
            not             => $not,
            parent          => $self,
        } );

    weaken( $constraint->{parent} );

    # inlined ObjectUtil::populate(), otherwise circular dependency
    eval {
        map { $constraint->$_( $arg->{$_} ) } keys %$arg;
    };
    croak $@ if $@;

    return $constraint;
}

sub get_errors {
    my $self = shift;
    my %args = _parse_args(@_);
    
    return [] if !$self->form->submitted;

    my @e = map { @{ $_->get_errors(@_) } } @{ $self->_elements };
    
    if ( exists $args{name} ) {
        @e = grep { $_->name eq $args{name} } @e;
    }
    
    if ( exists $args{type} ) {
        @e = grep { $_->type eq $args{type} } @e;
    }
    
    if ( exists $args{stage} ) {
        @e = grep { $_->stage eq $args{stage} } @e;
    }
    
    return \@e;
}

sub get_error {
    my $self = shift;
    
    return if !$self->form->submitted;

    my $c = $self->get_errors(@_);

    return @$c ? $c->[0] : ();
}

sub delete_errors {
    my ($self) = @_;
    
    map { $_->delete_errors } @{ $self->_elements };
    
    return;
}

sub populate {
    my ( $self, $arg ) = @_;

    my @keys = qw(
        element_defaults auto_fieldset load_config_file element elements 
        filter filters constraint constraints inflator inflators 
        deflator deflators query validator validators transformer transformers
    );

    my %defer;
    for (@keys) {
        $defer{$_} = delete $arg->{$_} if exists $arg->{$_};
    }

    eval {
        map { $self->$_( $arg->{$_} ) } keys %$arg;

        map      { $self->$_( $defer{$_} ) }
            grep { exists $defer{$_} } @keys;
    };
    croak $@ if $@;

    return $self;
}

sub insert_before {
    my ( $self, $object, $position ) = @_;
    
    for my $i ( 1 .. @{ $self->_elements } ) {
        if ( refaddr( $self->_elements->[$i-1] ) eq refaddr($position) ) {
            splice @{ $self->_elements }, $i-1, 0, $object;
            $object->{parent} = $position->{parent};
            weaken $object->{parent};
            return $object;
        }
    }
    
    croak 'position element not found';
}

sub insert_after {
    my ( $self, $object, $position ) = @_;
    
    for my $i ( 1 .. @{ $self->_elements } ) {
        if ( refaddr( $self->_elements->[$i-1] ) eq refaddr($position) ) {
            splice @{ $self->_elements }, $i, 0, $object;
            $object->{parent} = $position->{parent};
            weaken $object->{parent};
            return $object;
        }
    }
    
    croak 'position element not found';
}

sub load_config_file {
    my $self = shift;
    my @filenames;
    
    if ( @_ == 1 && ref $_[0] eq 'ARRAY' ) {
        push @filenames, @{ $_[0] };
    }
    else {
        push @filenames, @_;
    }
    
    for (@filenames) {
        croak "file not found: '$_'" if !-f $_;
    }

    my $files = Config::Any->load_files( {
            files   => \@filenames,
            use_ext => 1,
        } );

    my %config;
    for my $file (@$files) {
        %config = ( %config, %{ $file->{ ( keys %$file )[0] } } );
    }

    $self->populate( \%config );

    return $self;
}

sub _render_class {
    my ( $self, $dir ) = @_;

    if ( defined $self->render_class ) {
        return $self->render_class;
    }
    elsif ( defined $dir ) {
        return $self->render_class_prefix . "::" . $dir . "::"
            . $self->render_class_suffix;
    }
    else {
        return $self->render_class_prefix . "::"
            . $self->render_class_suffix;
    }
}

sub _coerce {
    my ( $self, %args ) = @_;

    for (qw/ type attributes package /) {
        croak "$_ argument required" if !defined $args{$_};
    }

    croak "type argument required" if !defined $args{type};

    my $class = $args{type};
    if ( $class !~ /^\+/ ) {
        $class = "HTML::FormFu::Element::$class";
    }

    require_class($class);

    my $element = $class->new( {
            name         => $self->name,
            element_type => $args{type},
            errors       => $args{errors},
        } );

    for my $method (
        qw/ attributes comment comment_attributes label label_attributes
        label_filename render_method parent /
        )
    {
        $element->$method( $self->$method );
    }

    $element->attributes( $args{attributes} );

    croak "element cannot be coerced to type '$args{type}'"
        if !$element->isa( $args{package} );

    my $render = $element->render;

    $render->{value} = $self->value;

    return $render;
}

sub form {
    my ($self) = @_;
    
    while ( defined $self->parent ) {
        $self = $self->parent;
    }
    
    return $self;
}

sub clone {
    my ( $self ) = @_;
    
    my %new = %$self;
    
    $new{_elements}         = [ map { $_->clone } @{ $self->_elements } ];
    $new{attributes}        = dclone $self->attributes;
    $new{render_class_args} = dclone $self->render_class_args;
    $new{element_defaults}  = dclone $self->element_defaults;
    $new{languages}         = dclone $self->languages;
    
    return bless \%new, ref $self;
}

sub name {
    my $self = shift;
    
    croak 'cannot use name() as a setter' if @_;
    
    return $self->parent->name;
}

sub stash {
    my $self = shift;
    
    $self->{stash} = {} if not exists $self->{stash};
    return $self->{stash} if !@_;

    my %attrs = ( @_ == 1 ) ? %{ $_[0] } : @_;

    $self->{stash}->{$_} = $attrs{$_} for keys %attrs;

    return $self;
};

1;
