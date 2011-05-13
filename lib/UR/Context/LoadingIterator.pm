package UR::Context::LoadingIterator;

use strict;
use warnings;

use UR::Context;

our $VERSION = "0.31"; # UR $VERSION;

# A helper package for UR::Context to handling queries which require loading
# data from outside the current context.  It is responsible for collating 
# cached objects and incoming objects.  When create_iterator() is used in
# application code, this is the iterator that gets returned
# 
# These are normal Perl objects, not UR objects, so they get regular
# refcounting and scoping

our @CARP_NOT = qw( UR::Context );

# A boolean flag used in the loading iterator to control whether we need to
# inject loaded objects into other loading iterators' cached lists
my $is_multiple_loading_iterators = 0;

my %all_loading_iterators;


# Some thoughts about the loading iterator's behavior around changing objects....
#
# The system attempts to return objects matching the rule at the time the iterator is
# created, even if they change between the time it's created and when next() returns 
# them.  There is a problem if the object in question is actually deleted (ie. isa
# UR::DeletedRef).  Since DeletedRef's die any time you try to use them, the object
# sorters can't sort them.  Instead, we'll just punt and throw an exception ourselves
# if we come across one.
# 
# This seems like the least suprising thing to do, but there are other solutions:
# 1) just plain don't return the deleted object
# 2) use signal_change to register a callback which will remove objects being deleted
#    from all the in-process iterator @$cached lists (accomplishes the same as #1).
#    For completeness, this may imply that other signal_change callbacks would remove
#    objects that no longer match rules for in-process iterators, and that means that 
#    next() returns things true at the time next() is called, not when the iterator
#    is created.
# 3) Put in some additional infrastructure so we can pull out the ID of a deleted
#    object.  That lets us call $next_object->id at the end of the closure, and return these
#    deleted objects back to the user.  Problem being that the user then can't really
#    do anything with them.  But it would be consistent about returning _all_ objects
#    that matched the rule at iterator creation time
# 4) Like #3, but just always return the deleted object before any underlying_context
#    object, and then don't try to get its ID at the end if the iterator if it's deleted



sub _create {
    my($class, $cached, $context, $normalized_rule, $data_source, $this_get_serial ) = @_;


    my $underlying_context_iterator = $context->_create_import_iterator_for_underlying_context(
              $normalized_rule, $data_source, $this_get_serial);

    my $is_monitor_query = $context->monitor_query;

    # These are captured by the closure...
    my($last_loaded_id, $next_obj_current_context, $next_obj_underlying_context);

    my $object_sorter = $normalized_rule->template->sorter();

    my $bx_subject_class = $normalized_rule->subject_class_name;

    # Collection of object IDs that were read from the DB query.  These objects are for-sure
    # not deleted, even though a cached object for it might have been turned into a ghost or
    # had its properties changed
    my %db_seen_ids_that_are_not_deleted;

    # Collection of object IDs that were read from the cached object list and haven't been
    # seen in the lsit of results from the database (yet).  It could be missing from the DB
    # results because that row has been deleted, because the DB row still exists but has been
    # changed since we loaded it and now doesn't match the BoolExp, or because we're sorting
    # results by something other than just ID, that sorted property has been changed in the DB
    # and we haven't come across this row yet but will before.
    #
    # The short story is that if there is anything in this hash when the underlying context iterator
    # is exhausted, then the ID-ed object is really deleted, and should be an exception
    my %changed_objects_that_might_be_db_deleted;

    my $me_loading_iterator_as_string;  # See note below the closure definition

    my $underlying_context_objects_count = 0;
    my $cached_objects_count = 0;

    # knowing if an object's changed properties are one of the rule's order-by
    # properties helps later on in the loading process of detecting deleted DB rows
    my %order_by_properties;
    if ($normalized_rule->template->order_by) {
        %order_by_properties = map { $_ => 1 } @{ $normalized_rule->template->order_by };
    }
    my $change_is_order_by_property = sub {
        foreach my $prop_name ( shift->_changed_property_names ) {
            return 1 if exists($order_by_properties{$prop_name});
        }
        return;
    };

    my $loading_iterator = sub {

        my $next_object;

        PICK_NEXT_OBJECT_FOR_LOADING:
        while (! $next_object) {
            if ($underlying_context_iterator && ! $next_obj_underlying_context) {
                ($next_obj_underlying_context) = $underlying_context_iterator->(1);

                $underlying_context_objects_count++ if ($is_monitor_query and $next_obj_underlying_context);

                # See if this newly loaded object needs to be inserted into any of the other
                # loading iterators' cached list.  We only need to check this is there is more
                # than one iterator running....
                if ($next_obj_underlying_context and $is_multiple_loading_iterators) {
                    $class->_inject_object_into_other_loading_iterators($next_obj_underlying_context, $me_loading_iterator_as_string);
                }
            }

            unless ($next_obj_current_context) {
                ($next_obj_current_context) = shift @$cached;
                $cached_objects_count++ if ($is_monitor_query and $next_obj_current_context);
            }

            if ($next_obj_current_context and $next_obj_current_context->isa('UR::DeletedRef')) {
                 my $obj_to_complain_about = $next_obj_current_context;
                 # undef it in case the user traps the exception, next time we'll pull another off the list
                 $next_obj_current_context = undef;
                 Carp::croak("Attempt to fetch an object which matched $normalized_rule when the iterator was created, "
                             . "but was deleted in the meantime:\n"
                             . Data::Dumper::Dumper($obj_to_complain_about) );
            }

            if (!$next_obj_underlying_context) {

                if ($is_monitor_query) {
                    $context->_log_query_for_rule($bx_subject_class,
                                                  $normalized_rule,
                                                  "QUERY: loaded $underlying_context_objects_count object(s) total from underlying context.");
                }
                $underlying_context_iterator = undef;

                # Anything left in this hash when the DB iterator is exhausted are object we expected to
                # see by now and must be deleted.  If any of these object have changes then
                # the __merge below will throw an exception
                foreach my $problem_obj (values(%changed_objects_that_might_be_db_deleted)) {
                    $context->__merge_db_data_with_existing_object($bx_subject_class, $problem_obj, undef, []);
                }

            }
            elsif (defined($last_loaded_id)
                   and
                   $last_loaded_id eq $next_obj_underlying_context->id)
            {
                # during a get() with -hints or is_many+is_optional (ie. something with an
                # outer join), it's possible that the join can produce the same main object
                # as it's chewing through the (possibly) multiple objects joined to it.
                # Since the objects will be returned sorted by their IDs, we only have to
                # remember the last one we saw
                # FIXME - is this still true now that the underlying context iterator and/or
                # object fabricator hold off on returning any objects until all the related
                # joined data bas been loaded?
                $next_obj_underlying_context = undef;
                redo PICK_NEXT_OBJECT_FOR_LOADING;
            }

            # decide which pending object to return next
            # both the cached list and the list from the database are sorted separately but with
            # equivalent algorithms (we hope).
            #
            # we're collating these into one return stream here

            my $comparison_result = undef;
            if ($next_obj_underlying_context && $next_obj_current_context) {
                $comparison_result = $object_sorter->($next_obj_underlying_context, $next_obj_current_context);
            }
print "cached obj id ".(defined($next_obj_current_context) ? $next_obj_current_context->id : "undef");
print "  DB obj id ".(defined($next_obj_underlying_context) ? $next_obj_underlying_context->id : "undef") ."\n";


            # This if() section is for when the in-memory and DB iterators return the same
            # object at the same time.
            if (
                $next_obj_underlying_context
                and $next_obj_current_context
                and $comparison_result == 0 # $next_obj_underlying_context->id eq $next_obj_current_context->id
            ) {
                # Both objects sort the same.  Since the ID properties are always last in the sort order list,
                # this means both objects must be the same object.
                $context->_log_query_for_rule($bx_subject_class, $normalized_rule, "QUERY: loaded object was already cached") if ($is_monitor_query);
                $next_object = $next_obj_current_context;
                $next_obj_current_context = undef;
                $next_obj_underlying_context = undef;
            }

            # This if() section is for when the DB iterator's object sorts first
            elsif (
                $next_obj_underlying_context
                and (
                    (!$next_obj_current_context)
                    or
                    ($comparison_result < 0) # ($next_obj_underlying_context->id le $next_obj_current_context->id) 
                )
            ) {
print "DB object sorts first\n";
                # db object sorts first
                # If we deleted it from memorym the DB would not have given it back.
                # So it either failed to match the BX now, or one of the order-by parameters changed
                if ($next_obj_underlying_context->__changes__) {
                     
                    # See if one of the changes is an order-by property
                    if ($change_is_order_by_property->($next_obj_underlying_context)) {
                        # If the object has changes, and one of the changes is one of the
                        # order-by properties, then the object will:
                        # 1) Already have appeared as $next_obj_current_context.
                        #    it will be in $changed_objects_that_might_be_db_deleted - remove it from that list
                        # 2) Will appear later as $next_obj_current_context.
                        #    Mark here that it's not deleted
                        my $next_obj_underlying_context_id = $next_obj_underlying_context->id;
                        unless (delete $changed_objects_that_might_be_db_deleted{$next_obj_underlying_context_id}) {
                            $db_seen_ids_that_are_not_deleted{$next_obj_underlying_context_id} = 1;
                        }
                    }
                    # If the object has any changes, then it will appear in the cached object list in
                    # $next_object_current_context at the appropriate time.  For the case where the
                    # object no longer matches the BoolExpr, then the appropriate time is never.
                    # Discard this object from the DB and pick again
                    $next_obj_underlying_context = undef;
                    redo PICK_NEXT_OBJECT_FOR_LOADING;

                } else {
                    # If the object has no changes, it must be something newly brought into the system.
                    $next_object = $next_obj_underlying_context;
                    $next_obj_underlying_context = undef;
                    last PICK_NEXT_OBJECT_FOR_LOADING;
                }
            }

            # This if() section is for when the in-memory iterator's object sorts first
            elsif (
                $next_obj_current_context
                and (
                    (!$next_obj_underlying_context)
                    or
                    ($comparison_result > 0) # ($next_obj_underlying_context->id ge $next_obj_current_context->id) 
                )
            ) {
print "cached object sorts first\n";
                # The cached object sorts first
                # Either it was changed in memory, in the DB or both
                # In addition, the change could have been to an order-by property, one of the
                # properties in the BoolExpr, or both

                my $next_obj_current_context_id = $next_obj_current_context->id;
                if ($context->object_exists_in_underlying_context($next_obj_current_context)) {
print "    cached object exists in underlying context\n";
                    if ($next_obj_current_context->__changes__) {
print "    cached object has changes\n";
                        if ($change_is_order_by_property->($next_obj_current_context)) {
print "    change is an order-by property\n";

                            # This object is expected to exist in the underlying context, has changes, and at
                            # least one of those changes is to an order-by property
                            #
                            # if it's in %db_seen_ids_that_are_not_deleted, then it was seen earlier
                            # from the DB, and can now be removed from that hash.
                            unless (delete $db_seen_ids_that_are_not_deleted{$next_obj_current_context_id}) {
                                # If not in that list, then add it to the list of things we might see later
                                # in the DB iterator.  If we don't see it by the end if the iterator, it
                                # must have been deleted from the DB.  At that time, we'll throw an exception.
                                # It's later than we'd like, since the caller has already gotten ahold of the
                                # object, but better late than never.  The alternative is to do an id-only
                                # query right now, but that would be inefficient.
                                #
                                # We could avoid storing this if we could verify that the db_committed/db_saved_uncommitted
                                # values did NOT match the BoolExpr, but this will suffice for now.
                                $changed_objects_that_might_be_db_deleted{$next_obj_current_context_id} = $next_obj_current_context;
                            }
                            # In any case, return the cached object.
                            $next_object = $next_obj_current_context;
                            $next_obj_current_context = undef;
                            last PICK_NEXT_OBJECT_FOR_LOADING;
                        }
                        else {
print "    change is NOT an order-by property\n";
                            # The change is not an order-by property.  This object must have been deleted
                            # from the DB.  The call to __merge below will throw an exception
                            $next_obj_current_context = undef;
                            $context->__merge_db_data_with_existing_object($bx_subject_class, $next_obj_current_context, undef, []);
                            redo PICK_NEXT_OBJECT_FOR_LOADING;
                        }

                    } else {
print "    cached object has NO changes\n";
                        # This cached object has no changes, so the database must have changed.
                        # It could be deleted, no longer match the BoolExpr, or have changes in an order-by property

                        if (delete $db_seen_ids_that_are_not_deleted{$next_obj_current_context_id}) {
print "    was already seen in the DB iterator\n";
                            # We saw this already on the DB iterator.  It's not deleted. Go ahead and return it
                            $next_object = $next_obj_current_context;
                            $next_obj_current_context = undef;
                            last PICK_NEXT_OBJECT_FOR_LOADING;

                        }
                        elsif ($normalized_rule->is_id_only) {
print "    normalized rule is id-only\n";
                            # If the query is id-only, and we didn't see the DB object at the same time, then
                            # the DB row must have been deleted.  Changing the PK columns in the DB are logically
                            # the same as deleting the old object and creating/defineing a new one in UR.
                            #
                            # The __merge will delete the cached object, then pick again
                            $context->__merge_db_data_with_existing_object($bx_subject_class, $next_obj_current_context, undef, []);
                            $next_obj_current_context = undef;
                            redo PICK_NEXT_OBJECT_FOR_LOADING;

                        } else {
                            # Force an ID-only query to the underying context
print "    trying id-only query to the DB for id ".$next_obj_current_context_id."\n";
                            my $requery_obj = $context->reload($bx_subject_class, id => $next_obj_current_context_id);
                            if ($requery_obj) {
print "    That object still exists\n";
                                # An object will that ID really does exist in the DB
                                # It has had the DB changes merged with the in-memory state.  See if the object
                                # still matches the BoolExpr
                                # NOTE: I don't think it matters now whether it matches the bx or not.
                                # 
                                #if ($normalized_rule->evaluate($requery_obj)) {
                                #    # This object must have had changes to the DB on an order-by column causing
                                #    # it to sort later.  Put it in the list of things to watch for later
                                #    $changed_objects_that_might_be_db_deleted{$next_obj_current_context_id} = $next_obj_current_context;
                                #}
                                # In any case, the DB iterator will pull it up at the appropriate time,
                                # and since the object has no changes, it will be returned to the caller then.
                                # Discard this in-memory object and pick again
                                $next_obj_current_context = undef;
                                redo PICK_NEXT_OBJECT_FOR_LOADING;

                            } else {
print "    that object is not in the DB - it is deleted\n";
                                # We've now confirmed that the object in the DB is really gone
                                # NOTE: wouldn't the reload() have performed the __merge (implying deletion)
                                # in the above branch "elsif ($normalized_rule->is_id_only)" ??
                                #$context->__merge_db_data_with_existing_object($bx_subject_class, $next_obj_current_context, undef, []);
                                $next_obj_current_context = undef;
                                redo PICK_NEXT_OBJECT_FOR_LOADING;
                            }
                        }
                    }
                } else {
print "    It is a newly created object\n";
                    # The object does not exist in the underlying context.  It must be
                    # a newly created object.
                    $next_object = $next_obj_current_context;
                    $next_obj_current_context = undef;
                    last PICK_NEXT_OBJECT_FOR_LOADING;
                }

            } elsif (!defined($next_obj_current_context)
                     and
                     !defined($next_obj_underlying_context)
            ) {
                # Both iterators are exhausted.  Bail out
print "Both iterators are done\n";
                $next_object = undef;
                $last_loaded_id = undef;
                last PICK_NEXT_OBJECT_FOR_LOADING;

            } else {
                # Couldn't decide which to pick next? Something has gone horribly wrong.
                # We're using other vars to hold the objects and setting
                # $next_obj_current_context/$next_obj_underlying_context to undef so if
                # the caller is trapping exceptions, this iterator will pick new objects next time
                my $current_problem_obj = $next_obj_current_context;
                my $underlying_problem_obj = $next_obj_underlying_context;
                $next_obj_current_context = undef;
                $next_obj_underlying_context = undef;
                $next_object = undef;
                Carp::croak("Loading iterator internal error.  Could not pick an next object for loading.\n"
                            . "Next object underlying context: " . Data::Dumper::Dumper($underlying_problem_obj)
                            . "\nNext object current context: ". Data::Dumper::Dumper($current_problem_obj));
 
            }

            return unless defined $next_object;
        } # end while ! $next_object

        $last_loaded_id = $next_object->id if $next_object;
print "Returning obj id $last_loaded_id\n" if(defined $last_loaded_id);

        return $next_object;
    };  # end of the closure

    bless $loading_iterator, $class;
    Sub::Name::subname($class . '__loading_iterator_closure__', $loading_iterator);

    # Inside the closure, it needs to know its own address, but without holding a real reference
    # to itself - otherwise the closure would never go out of scope, the destructor would never
    # get called, and the list of outstanding loaders would never get pruned.  This way, the closure
    # holds a reference to the string version of its address, which is the only thing it really
    # needed anyway
    $me_loading_iterator_as_string = $loading_iterator . '';
print "Starting a new loading iterator for $normalized_rule $me_loading_iterator_as_string\n";

    $all_loading_iterators{$me_loading_iterator_as_string} = 
        [ $me_loading_iterator_as_string,
          $normalized_rule,
          $object_sorter,
          $cached,
          \$underlying_context_objects_count,
          \$cached_objects_count,
          $context,
      ];

    $is_multiple_loading_iterators = 1 if (keys(%all_loading_iterators) > 1);

    return $loading_iterator;
} # end _create()



sub DESTROY {
    my $self = shift;

print "Loading iterator $self is going out of scope\n";
    my $iter_data = $all_loading_iterators{$self};
    if ($iter_data->[0] eq $self) {
        # that's me!

        # Items in the listref are: $loading_iterator_string, $rule, $object_sorter, $cached,
        # \$underlying_context_objects_count, \$cached_objects_count, $context

        my $context = $iter_data->[6];
        if ($context->monitor_query) {
            my $rule = $iter_data->[1];
            my $count = ${$iter_data->[4]} + ${$iter_data->[5]};
            $context->_log_query_for_rule($rule->subject_class_name, $rule, "QUERY: Query complete after returning $count object(s) for rule $rule.");
            $context->_log_done_elapsed_time_for_rule($rule);
        }
        delete $all_loading_iterators{$self};
        $is_multiple_loading_iterators = 0 if (keys(%all_loading_iterators) < 2);

    } else {
        Carp::carp('A loading iterator went out of scope, but could not be found in the registered list of iterators');
    }
}


# Used by the loading itertor to inject a newly loaded object into another
# loading iterator's @$cached list.  This is to handle the case where the user creates
# an iterator which will load objects from the DB.  Before all the data from that
# iterator is read, another get() or iterator is created that covers (some of) the same
# objects which get pulled into the object cache, and the second request is run to
# completion.  Since the underlying context iterator has been changed to never return
# objects currently cached, the first iterator would have incorrectly skipped ome objects that
# were not loaded when the first iterator was created, but later got loaded by the second.
sub _inject_object_into_other_loading_iterators {
    my($self, $new_object, $iterator_to_skip) = @_;

    ITERATOR:
    foreach my $iter_name ( keys %all_loading_iterators ) {
        next if $iter_name eq $iterator_to_skip;  # That's me!  Don't insert into our own @$cached this way
        my($loading_iterator, $rule, $object_sorter, $cached)
                                = @{$all_loading_iterators{$iter_name}};
        if ($rule->evaluate($new_object)) {

            my $cached_list_len = @$cached;
            for(my $i = 0; $i < $cached_list_len; $i++) {
                my $cached_object = $cached->[$i];
                next if $cached_object->isa('UR::DeletedRef');

                my $comparison = $object_sorter->($new_object, $cached_object);

                if ($comparison < 0) {
                    # The new object sorts sooner than this one.  Insert it into the list
                    splice(@$cached, $i, 0, $new_object);
                    next ITERATOR;
                } elsif ($comparison == 0) {
                    # This object is already in the list
                    next ITERATOR;
                }
            }

            # It must go at the end...
            push @$cached, $new_object;
        }
    } # end foreach
}


# Reverse of _inject_object_into_other_loading_iterators().  Used when one iterator detects that
# a previously loaded object no longer exists in the underlying context/datasource
sub _remove_object_from_other_loading_iterators {
    my($self, $disappearing_object, $iterator_to_skip) = @_;

#print "In _remove_object_from_other_loading_iterators, count is $iterator_count\n";
$DB::single=1;
    ITERATOR:
    foreach my $iter_name ( keys %all_loading_iterators ) {
        next if(! defined $iterator_to_skip or ($iter_name eq $iterator_to_skip));  # That's me!  Don't remove into our own @$cached this way
        my($loading_iterator, $rule, $object_sorter, $cached)
                                = @{$all_loading_iterators{$iter_name}};
        next if (defined($iterator_to_skip)
                  and $loading_iterator eq $iterator_to_skip);  # That's me!  Don't insert into our own @$cached this way
#print "Evaluating rule $rule against object ".Data::Dumper::Dumper($disappearing_object),"\n";
        if ($rule->evaluate($disappearing_object)) {
#print "object matches rule\n";

            my $cached_list_len = @$cached;
#print "there are $cached_list_len objects in the cached list: ",join(',',map { $_->id } @$cached),"\n";
            for(my $i = 0; $i < $cached_list_len; $i++) {
                my $cached_object = $cached->[$i];
                next if $cached_object->isa('UR::DeletedRef');

                my $comparison = $object_sorter->($disappearing_object, $cached_object);

#print "cached obj id ".$cached_object->id." comparison $comparison\n";
                if ($comparison == 0) {
                    # That's the one, remove it from the list
#print "removing obj id ".$disappearing_object->id." from loading iterator $loading_iterator cache\n";
                    splice(@$cached, $i, 1);
                    next ITERATOR;
                } elsif ($comparison < 0) {
                    # past the point where we expect to find this object
                    next ITERATOR;
                }
            }
        }
    } # end foreach
}


# Returns true if any of the object's changed properites are keys
# in the passed-in hashref.  Used by the Loading Iterator to find out if
# a change is one of the order-by properties of a bx
sub _changed_property_in_hash {
    my($self,$object,$hash) = @_;

    foreach my $prop_name ( $object->_changed_property_names ) {
        return 1 if (exists $hash->{$prop_name});
    }
    return;
}
1;

