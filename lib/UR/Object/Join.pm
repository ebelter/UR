package UR::Object::Join;
use strict;
use warnings;
use UR;
our $VERSION = "0.38"; # UR $VERSION;

our @CARP_NOT = qw( UR::Object::Property );

class UR::Object::Join {
    #is => 'UR::Value',
    id_by => [
        id                      => { is => 'Text' },
    ],
    has_optional_transient => [
        source_class            => { is => 'Text' },
        source_property_names   => { is => 'Text' },
        
        foreign_class           => { is => 'Text' },
        foreign_property_names  => { is => 'Text' },
        
        source_name_for_foreign => { is => 'Text' },
        foreign_name_for_source => { is => 'Text' },
        
        is_optional             => { is => 'Boolean' }, 

        is_many                 => { is => 'Boolean' },

        sub_group_label         => { is => 'Text' },

        where                   => { is => 'Text' },
    ],
    doc => "join metadata used internally by the ::QueryBuilder"
};

our %resolve_chain;
sub resolve_chain {
    my ($class, $class_name, $property_chain, $join_label) = @_;

    $join_label ||= $property_chain;

    my $join_chain = 
        $resolve_chain{$class_name}{$join_label}{$property_chain}
            ||= do {
                my $class_meta = $class_name->__meta__;
                my @joins;
                if (index($property_chain,'.') != -1) {
                    # dot-syntax: call ourselves recursively
                    my @chain = split(/\./,$property_chain);
                    my $last_class_name = $class_name;
                    my $last_class_meta = $class_meta;
                    for my $full_link (@chain) {
                        my ($link) = ($full_link =~ /^([^\-\?]+)/);
                        #push @pmeta, $property_meta;
                        #last if $link eq $chain[-1];
                        my @new_joins = UR::Object::Join->resolve_chain($last_class_name, $link);
                        #return unless @new_joins;
                        if (@joins and @new_joins) {
                            ($joins[-1],$new_joins[0]) = $class->connect_pair( $joins[-1], $new_joins[0]);
                        }
                        push @joins, @new_joins;
                        $last_class_name = $new_joins[-1]{foreign_class};
                        $last_class_meta = $last_class_name->__meta__;
                    }
                }
                else {
                    # regular syntax: 
                    my $pmeta = $class_meta->property_meta_for_name($property_chain);
                    @joins = $class->_resolve_chain_for_property_meta($pmeta,$join_label);
                }

                # return the arrayref to cache the value
                \@joins;
            };

    return @$join_chain;
}

sub connect_pair {
    my ($class, $j1, $j2) = @_;
    my $j1_class_name = $j1->foreign_class;
    my $j2_class_name = $j2->source_class;
    if ($j1_class_name ne $j2_class_name) {
        if ($j2_class_name->isa($j1_class_name)) {
            my $new_j1 = UR::Object::Join->_get_or_define(
                source_class => $j1->source_class,
                source_property_names => $j1->source_property_names,
                foreign_class => $j2_class_name, # more specific 
                foreign_property_names => $j1->foreign_property_names, # presume the borrow took you into a subclass and these still work
                is_optional => $j1->is_optional,
                id => $j1->{id} . ' isa ' . $j2_class_name
            );
            print "swap j1 \n" . Data::Dumper::Dumper($j1,$new_j1);
            return ($new_j1,$j2); 
        }
        elsif($j1_class_name->isa($j2_class_name)) {
            my $new_j2 = UR::Object::Join->_get_or_define(
                source_class => $j1_class_name, 
                source_property_names => $j2->source_property_names,
                foreign_class => $j2->foreign_class, # more specific 
                foreign_property_names => $j2->foreign_property_names, # presume the borrow took you into a subclass and these still work
                is_optional => $j2->is_optional,
                id => $j2->{id} . ' isa ' . $j2_class_name
            );
            print "swap j2 \n" . Data::Dumper::Dumper($j2,$new_j2);
            return ($j1,$new_j2); 
        }
    }
    return ($j1,$j2);
}

sub _resolve_chain_for_property_meta {
    my ($class, $pmeta, $join_label) = @_;  
    if ($pmeta->via or $pmeta->to) {
        return $class->_resolve_via_to($pmeta,$join_label);
    }
    else {
        my $foreign_class = $pmeta->_data_type_as_class_name;
        unless (defined($foreign_class) and $foreign_class->can('get'))  {
            return;
        }
        if ($pmeta->id_by or $foreign_class->isa("UR::Value")) {
            return $class->_resolve_forward($pmeta, $join_label);
        }
        elsif (my $reverse_as = $pmeta->reverse_as) { 
            return $class->_resolve_reverse($pmeta,$join_label);
        }
        else {
            # TODO: handle hard-references to objects here maybe?
            $pmeta->error_message("Property " . $pmeta->id . " has no 'id_by' or 'reverse_as' property metadata");
            return;
        }
    }
}

sub _get_or_define {
    my $class = shift;
    my %p = @_;
    my $id = delete $p{id};
    delete $p{__get_serial};
    delete $p{db_committed};
    delete $p{_change_count};
    delete $p{__defined};
    my $self = $class->get(id => $id);
    unless ($self) {
        $self = $class->__define__($id);
        for my $k (keys %p) {
            $self->$k($p{$k});
            no warnings;
            unless ($self->{$k} eq $p{$k}) {
                Carp::confess(Data::Dumper::Dumper($self, \%p));
            }   
        }
    }
    unless ($self) {
        Carp::confess("Failed to create join???");
    }
    return $self;
}

sub _resolve_via_to {
    my ($class, $pmeta,$join_label) = @_;

    my $class_name = $pmeta->class_name;
    my $class_meta = UR::Object::Type->get(class_name => $class_name);

    my @joins;
    my $via = $pmeta->via;

    my $to = $pmeta->to;    
    if ($via and not $to) {
        $to = $pmeta->property_name;
    }

    my $via_meta;
    if ($via) {
        $via_meta = $class_meta->property_meta_for_name($via);
        unless ($via_meta) {
            return if $class_name->can($via);  # It's via a method, not an actual property

            my $property_name = $pmeta->property_name;
            my $class_name = $pmeta->class_name;
            Carp::croak "Can't resolve joins for property '$property_name' of $class_name: No property metadata for via property '$via'";
        }

        if ($via_meta->to and ($via_meta->to eq '-filter')) {
            return $class->resolve_chain($via_meta->class_name, $via_meta->property_name, $join_label);
        }

        unless ($via_meta->data_type) {
            my $property_name = $pmeta->property_name;
            my $class_name = $pmeta->class_name;
            Carp::croak "Can't resolve joins for property '$property_name' of $class_name: No data type for via property '$via'";
        }
        push @joins, $class->resolve_chain($via_meta->class_name, $via_meta->property_name, $join_label);
        
        if (my $where = $pmeta->where) {
            my $join = pop @joins;
            unless ($join and $join->{foreign_class}) {
                my $property_name = $pmeta->property_name;
                my $class_name = $pmeta->class_name;
                Carp::croak("Can't resolve joins for property '$property_name' of $class_name: Couldn't determine foreign class for via property '$via'\n"
                            . "join data so far: ".  Data::Dumper::Dumper($join, \@joins));
            }
            my $where_rule = UR::BoolExpr->resolve($join->{foreign_class}, @$where);                
            my $id = $join->{id};
            $id .= ' ' . $where_rule->id . ":$join_label";
            my %join_data = %$join;
            push @joins, $class->_get_or_define(%join_data, id => $id, where => $where, sub_group_label => $pmeta->property_name);
        }
    }
    else {
        $via_meta = $pmeta;
    }

    if ($to and $to ne '__self__' and $to ne '-filter') {
        my $to_class_meta = eval { $via_meta->data_type->__meta__ };
        unless ($to_class_meta) {
            Carp::croak("Can't get class metadata for " . $via_meta->data_type
                        . " while resolving property '" . $pmeta->property_name . "' in class " . $pmeta->class_name . "\n"
                        . "Is the data_type for property '" . $via_meta->property_name . "' in class "
                        . $via_meta->class_name . " correct?");
        }

        my $to_meta = $to_class_meta->property_meta_for_name($to);
        unless ($to_meta) {
            my $property_name = $pmeta->property_name;
            my $class_name = $pmeta->class_name;
            Carp::croak "Can't resolve property '$property_name' of $class_name: No '$to' property found on " . $via_meta->data_type;
        }

        push @joins, $class->resolve_chain($to_meta->class_name, $to_meta->property_name, $join_label);
    }
   
    if (my $return_class_name = $pmeta->class->_convert_data_type_for_source_class_to_final_class($pmeta->data_type, $pmeta->class_name)) {
        my $final_class_name = $joins[-1]->foreign_class;
        if ($return_class_name ne $final_class_name) {
            if ($return_class_name->isa($final_class_name)) {
                # the property is a subclass of the one involved in the final join
                # this happens when there is a via/where/to where say "to" goes-to any "Animal" but this overall property is known to be a "Dog". 
                my $general_join = pop @joins;
                my $specific_join = UR::Object::Join->_get_or_define(
                    source_class => $general_join->{'source_class'},
                    source_property_names => $general_join->{'source_property_names'},
                    foreign_class => $return_class_name, # more specific 
                    foreign_property_names => $general_join->{'foreign_property_names'}, # presume the borrow took you into a subclass and these still work
                    is_optional => $general_join->{'is_optional'},
                    id => $general_join->{id} . ' isa ' . $return_class_name
                );
                push @joins, $specific_join;
            }
            elsif ($return_class_name eq 'UR::Value::SloppyPrimitive' or $final_class_name eq 'UR::Value::SloppyPrimitive') {
                # backward-compatible layer for before there were primitive types
            }
            elsif ($final_class_name->isa($return_class_name)) {
                warn "joins in $pmeta->{id} is declared as $return_class_name while its joins connect to a more specific $final_class_name!";
            }
            else {
                warn "incompatible join: $final_class_name is not a $return_class_name";
            }
        }
    }

    return @joins;
}

# code below uses these to convert objects using hash slices
my @old = qw/source_class source_property_names foreign_class foreign_property_names source_name_for_foreign foreign_name_for_source is_optional is_many sub_group_label/;
my @new = qw/foreign_class foreign_property_names source_class source_property_names foreign_name_for_source source_name_for_foreign is_optional is_many sub_group_label/;

sub _resolve_forward {
    my ($class, $pmeta, $join_label) = @_;

    my $foreign_class = $pmeta->_data_type_as_class_name;
    unless (defined($foreign_class) and $foreign_class->can('get'))  {
        #Carp::cluck("No metadata?!");
        return;
    }

    my $source_class = $pmeta->class_name;            
    my $class_meta = UR::Object::Type->get(class_name => $pmeta->class_name);
    my @joins;
    my $where = $pmeta->where;
    my $foreign_class_meta = $foreign_class->__meta__;
    my $property_name = $pmeta->property_name;

    my $id = $source_class . '::' . $property_name;
    if ($where) {
        my $where_rule = UR::BoolExpr->resolve($foreign_class, @$where);
        $id .= ' ' . $where_rule->id;
    }

    #####
    
    # direct reference (or primitive, which is a direct ref to a value obj)
    my (@source_property_names, @foreign_property_names);
    my ($source_name_for_foreign, $foreign_name_for_source);

    if ($foreign_class->isa("UR::Value")) {
        if (my $id_by = $pmeta->id_by) {
            my @id_by = ref($id_by) eq 'ARRAY' ? @$id_by : ($id_by);
            foreach my $id_by_name ( @id_by ) {
                my $id_by_property = $class_meta->property_meta_for_name($id_by_name);
                push @joins, $class->resolve_chain($id_by_property->class_name, $id_by_property->property_name, $join_label);
            }
        }

        @source_property_names = ($property_name);
        @foreign_property_names = ('id');

        $source_name_for_foreign = ($property_name);
    }
    elsif (my $id_by = $pmeta->id_by) { 
        my @pairs = $pmeta->get_property_name_pairs_for_join;
        @source_property_names  = map { $_->[0] } @pairs;
        @foreign_property_names = map { $_->[1] } @pairs;

        if (ref($id_by) eq 'ARRAY') {
            # satisfying the id_by requires joins of its own
            # sms: why is this only done on multi-value fks?
            foreach my $id_by_property_name ( @$id_by ) {
                my $id_by_property = $class_meta->property_meta_for_name($id_by_property_name);
                next unless ($id_by_property and $id_by_property->is_delegated);
            
                push @joins, $class->resolve_chain($id_by_property->class_name, $id_by_property->property_name, $join_label);
                $source_class = $joins[-1]->{'foreign_class'};
                @source_property_names = @{$joins[-1]->{'foreign_property_names'}};
            }
        }

        $source_name_for_foreign = $pmeta->property_name;
        my @reverse = $foreign_class_meta->properties(reverse_as => $source_name_for_foreign, data_type => $pmeta->class_name);
        my $reverse;
        if (@reverse > 1) {
            my @reduced = grep { not $_->where } @reverse;
            if (@reduced != 1) {
                Carp::confess("Ambiguous results finding reversal for $property_name!" . Data::Dumper::Dumper(\@reverse));
            }
            $reverse = $reduced[0];
        }
        else {
            $reverse = $reverse[0];
        }
        if ($reverse) {
            $foreign_name_for_source = $reverse->property_name;
        }
    }

    # the foreign class might NOT have a reverse_as, but
    # this records what to reverse in this case.
    $foreign_name_for_source ||= '<' . $source_class . '::' . $source_name_for_foreign;

    $id .= ":$join_label";

    push @joins, $class->_get_or_define( 
                    id => $id,

                    source_class => $source_class,
                    source_property_names => \@source_property_names,
                    
                    foreign_class => $foreign_class,
                    foreign_property_names => \@foreign_property_names,
                    
                    source_name_for_foreign => $source_name_for_foreign,
                    foreign_name_for_source => $foreign_name_for_source,
                    
                    is_optional => ($pmeta->is_optional or $pmeta->is_many),

                    is_many => $pmeta->is_many,

                    where => $where,
                );

    return @joins;
}

sub _resolve_reverse {
    my ($class, $pmeta,$join_label) = @_;

    my $foreign_class = $pmeta->_data_type_as_class_name;

    unless (defined($foreign_class) and $foreign_class->can('get'))  {
        #Carp::cluck("No metadata?!");
        return;
    }

    my $source_class = $pmeta->class_name;            
    my $class_meta = UR::Object::Type->get(class_name => $pmeta->class_name);
    my @joins;
    my $where = $pmeta->where;
    my $property_name = $pmeta->property_name;

    my $id = $source_class . '::' . $property_name;
    if ($where) {
        my $where_rule = UR::BoolExpr->resolve($foreign_class, @$where);
        $id .= ' ' . $where_rule->id;
    }

    #####
    
    my $reverse_as = $pmeta->reverse_as;

    my $foreign_class_meta = $foreign_class->__meta__;
    my $foreign_property_via = $foreign_class_meta->property_meta_for_name($reverse_as);
    unless ($foreign_property_via) {
        Carp::confess("No property '$reverse_as' in class $foreign_class, needed to resolve property '" .
                        $pmeta->property_name . "' of class " . $pmeta->class_name);
    }

    my @join_data = map { { %$_ } } reverse $class->resolve_chain($foreign_property_via->class_name, $foreign_property_via->property_name, $join_label);
    my $prev_where = $where;
    for (@join_data) { 
        @$_{@new} = @$_{@old};

        my $next_where = $_->{where};
        $_->{where} = $prev_where;

        my $id = $_->{source_class} . '::' . $_->{source_name_for_foreign};
        if ($prev_where) {
            my $where_rule = UR::BoolExpr->resolve($foreign_class, @$where);
            $id .= ' ' . $where_rule->id;

        }
        $id .= ":$join_label";
        $_->{id} = $id; 

        $_->{is_optional} = ($pmeta->is_optional || $pmeta->is_many);

        $_->{is_many} = $pmeta->{is_many};

        $_->{sub_group_label} = $pmeta->property_name;

        $prev_where = $next_where;
    }
    if ($prev_where) {
        #Carp::confess("final join needs placement! " . Data::Dumper::Dumper($prev_where));
    }

    for my $join_data (@join_data) {
        push @joins, $class->_get_or_define(%$join_data);
    }

    return @joins;
}


# Return true if the foreign-end of the join includes all the ID properties of
# the foreign class.  Used by the ObjectFabricator when it is determining whether or
# not to include more rules in the all_params_loaded hash for delegations
sub destination_is_all_id_properties {
    my $self = shift;

    my $foreign_class_meta = $self->{'foreign_class'}->__meta__;
    my %join_properties = map { $_ => 1 } @{$self->{'foreign_property_names'}};
    my $join_has_all_id_props = 1;
    foreach my $foreign_id_meta (  $foreign_class_meta->all_id_property_metas ) {
        next if $foreign_id_meta->class_name eq 'UR::Object';  # Skip the manufactured 'id' property
        next if (delete $join_properties{ $foreign_id_meta->property_name });
        $join_has_all_id_props = 0;
    }
    return $join_has_all_id_props;
}


1;
