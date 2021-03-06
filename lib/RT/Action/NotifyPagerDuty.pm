use strict;
use warnings;
use LWP::UserAgent;
use JSON;
use PagerDuty::Agent;

package RT::Action::NotifyPagerDuty;
use base qw(RT::Action);

our $VERSION = '0.02';

=head1 NAME

RT-Action-NotifyPagerDuty - Create or update an incident in PagerDuty

=head1 DESCRIPTION

This action allows you to create or update incidents in PagerDuty
when a ticket is created or updated in Request Tracker.

=head1 RT VERSION

Works with RT 4.4.x and above.

=head1 INSTALLATION

=over

=item C<perl Makefile.PL>

=item C<make>

=item C<make install>

May need root permissions

=item C<rt-setup-database --action insert --datafile db/initialdata>

May need root permissions

=item Edit your F</opt/rt4/etc/RT_SiteConfig.pm>

Add this line:

    Plugin('RT::Action::NotifyPagerDuty');

In PagerDuty.com add a new service, selection "Use our API directly" and
select "Events API v2" and whatever other settings you need. Take the routing
key they generate and add a line like this:

    Set ($PagerDutyRoutingKey, 'key_goes_here');

Other settings you may want to add, with their defaults:

    Set ($PagerDutyQueueCFService, 'Incident Service');

=item Restart your webserver

=item In RT, you need to create a new Scrip

Create for example a scrip with:

    Description: Create or Update PagerDuty Incident
    Condition:   On Transaction
    Action:      Notify PagerDuty
    Template:    Blank
    Stage:       Normal
    Enabled:     Yes

Then assign that scrip to the queues which you want to notify PagerDuty.

=back

=head1 CONFIGURATION

There are only a few settings that can be configured.

Currently you can set the PagerDuty priority and services to be used
via Queue CustomFields.

=over

=item AcknowledgeOnTake

Should the incident in PagerDuty be acknowledged if the ticket in RT
is Taken? Allow values: 0 or 1.

Defaults to 1.

To disable:

    Set ($PagerDutyAcknowledgeOnTake, 0);

=item QueueCFAcknowledgeOnTake

Allow the global AcknowledgeOnTake setting to be overridden by queue.

By default the Queue CustomField is named "Incident Acknowledge On Take",
but you can this with:

    Set ($PagerDutyQueueCFAcknowledgeOnTake, 'Incident Acknowledge On Take');

The allow values are: 1 or 0.

=item QueueCFPriority

The PagerDuty incident priority which this incident will be created using.

By default the Queue CustomField is named "Incident Priority", but you can
change that with:

    Set ($PagerDutyQueueCFPriority, 'Incident Priority');

The allowed values are: critical, warning, error, or info.

If no priority is set, or an invalid value is used, critical will be used.

=item QueueCFService

The PagerDuty service which this incident will be created using.

By default the Queue CustomField is named "Incident Service", but you can
change that with:

    Set ($PagerDutyQueueCFService, 'Incident Service');

If no service is defined, then RT is used.

=item Spool

A directory to spool submissions if PagerDuty have sent us a response
deferring our submission. This directory will need to be writable by
the process that is running Request Tracker (for example www-data).

By default it is unset, so if a submission is deferred it will be
deleted.

To set:

    Set ($PagerDutySpoolDir, '/opt/rt4/spool/pagerduty');

If you spool submissions then you should run rt-flush-pagerduty regularly,
for example from cron. No arguments are required for rt-flush-pagerduty.

=item Include SubjectTag

Prefix the summary if the incident submitted to PagerDuty with the
Request Tracker SubjectTag for the queue the ticket is in. This is
to allow an email address for RT (either correspond or comment) in the
notification set within PagerDuty to allow updates from PagerDuty to
be added to RT.

By default this is disabled.

To enable:

    Set ($PagerDutyIncludeSubjectTag, 1);

=back

=head1 AUTHOR

Andrew Ruthven, Catalyst Cloud Ltd E<lt>puck@catalystcloud.nzE<gt>

=for html <p>All bugs should be reported via email to <a
href="mailto:bug-RT-Extension-PagerDuty@rt.cpan.org">bug-RT-Extension-PagerDuty@rt.cpan.org</a>
or via the web at <a
href="http://rt.cpan.org/Public/Dist/Display.html?Name=RT-Extension-PagerDuty">rt.cpan.org</a>.</p>

=for text

    All bugs should be reported via email to
        bug-RT-Extension-PagerDuty@rt.cpan.org
    or via the web at
        http://rt.cpan.org/Public/Dist/Display.html?Name=RT-Extension-PagerDuty

=head1 LICENSE AND COPYRIGHT

This software is Copyright (c) 2019-2020 by Catalyst Cloud Ltd

This is free software, licensed under:

  The GNU General Public License, Version 2, June 1991

=cut

# As we use a custom RT::Transaction, we need to add our _BriefDescription.
{
    package RT::Transaction;
    our %_BriefDescriptions;

    $_BriefDescriptions{"PagerDuty"} = sub {
        return ("Incident [_1] in PagerDuty", $_[0]->NewValue);  #loc();
    };
}

sub Prepare {
    my $shelf = shift;

    return 1;
};

sub Commit {
    my $self = shift;

    # If the status is:
    #  - new, trigger an incident;
    #  - resolved, rejected or deleted, , resolve an incident;
    # If the owner is set, acknowledge the incident.

    # Should we Acknowledge an incident with a ticket in RT is taken?
    # Defaults to enabled.
    my $ticket = $self->TicketObj;
    my $queue  = $ticket->QueueObj;
    my $acknowledge_on_take = RT->Config->Get('PagerDutyAcknowledgeOnTake')
                              // 1;

    # Allow acknowledge_on_take to be overridden on a per Queue basis.
    my $queue_acknowledge_on_take_cf_name =
        RT->Config->Get('PagerDutyQueueCFAcknowledgeOnTake')
        || 'Incident Acknowledge On Take';
    my $q_acknowledge_on_take =
        $queue->FirstCustomFieldValue($queue_acknowledge_on_take_cf_name);
    $acknowledge_on_take = $q_acknowledge_on_take
        if defined $q_acknowledge_on_take;

    my ($pd_action, $pretty_action, $rt_action);
    my $txnObj = $self->TransactionObj;

    if ($txnObj->Type eq 'Create') {
        $pd_action     = 'trigger';
        $pretty_action = 'triggered';
        $rt_action     = 'creating';

    } elsif ($txnObj->Type eq 'Status'
             && $txnObj->OldValue !~ /^resolved|rejected|deleted$/
             && $txnObj->NewValue =~ /^resolved|rejected|deleted$/
            ) {
        $pd_action     = 'resolve';
        $pretty_action = 'resolved';
        $rt_action     = 'updating';

    } elsif ($txnObj->Type eq 'Set'
	     && $acknowledge_on_take
             && $txnObj->Field eq 'Owner'
             && $txnObj->NewValue != $RT::SystemUser->id
             && $txnObj->NewValue != $RT::Nobody->id
            ) {
        $pd_action     = 'acknowledge';
        $pretty_action = 'acknowledged';
        $rt_action     = 'updating';
    }

    # If $pd_action isn't set, then we have nothing to do.
    return 1 unless defined $pd_action;

    my $txn_content;
    my ($result, $error) = $self->_pagerduty_submit($pd_action);
    if (! defined $result) {
        $RT::Logger->error("Failed $rt_action incident on Pager Duty, error: $error");
        $pretty_action = 'rejected';
        $txn_content = "Failed $rt_action incident in PagerDuty: $error";
    } elsif ($result eq 'defer') {
        $RT::Logger->info("Pager Duty deferred $rt_action to raise incident on Pager Duty");
        $pretty_action = 'deferred';
        $txn_content = "Response from PagerDuty: $error";
    } else {
        $RT::Logger->info("Successfully raised incident on Pager Duty, dedup_key: $result");
        $txn_content = "Succeeded in $rt_action incident in PagerDuty";
    }

    # We need to give RT::Record::_NewTransaction a MIME object to have it
    # store our content for us.
    my $MIMEObj = MIME::Entity->build(
        Type    => "text/plain",
        Charset => "UTF-8",
        Data    => [ Encode::encode("UTF-8", $txn_content) ],
    );

    $self->TicketObj->_NewTransaction(
        Type     => 'PagerDuty',
        NewValue => $pretty_action,
        MIMEObj  => $MIMEObj,
    );

    return 1;
}

sub _pagerduty_submit {
    my ($self, $action) = @_;
    my $routing_key = RT->Config->Get('PagerDutyRoutingKey');
    my $spool_dir   = RT->Config->Get('PagerDutySpoolDir');

    my $agent     = PagerDuty::Agent->new(
        routing_key => $routing_key,
        spool       => $spool_dir,
    );
    my $dedup_key = 'rt#' . $self->TicketObj->id;

    if    ($action eq 'acknowledge') {
        return ($agent->acknowledge_event(dedup_key => $dedup_key, summary => 'Ticket in RT has an owner'), $@);

    } elsif ($action eq 'resolve') {
        return ($agent->resolve_event($dedup_key), $@);

    } elsif ($action eq 'trigger') {
        return ($self->_trigger_event($dedup_key, $agent), $@);
    }
}

sub _trigger_event {
    my ($self, $dedup_key, $agent) = @_;

    my $ticket = $self->TicketObj;
    my $queue  = $ticket->QueueObj;

    my $queue_priority_cf_name = RT->Config->Get('PagerDutyQueueCFPriority')
                                 || 'Incident Priority';
    my $queue_priority = $queue->FirstCustomFieldValue($queue_priority_cf_name);

    # Set the priority to what PagerDuty supports.
    if ($queue_priority) {
        $queue_priority = lc($queue_priority);
        if ($queue_priority !~ /^critical|warning|error|info$/) {
            $RT::Logger->error("Pager Duty priority is $queue_priority, which isn't supported by PD, changing to critical");
            $queue_priority = 'critical';
        }
    }

    my $queue_service_cf_name  = RT->Config->Get('PagerDutyQueueCFService')
                                 || 'Incident Service';
    my $queue_service  = $queue->FirstCustomFieldValue($queue_service_cf_name);

    # Should we include the SubjectTag in the incident raised in PagerDuty?
    # This will allow emails out of PagerDuty to be added to a ticket in RT.
    my $include_subject_tag = RT->Config->Get('PagerDutyIncludeSubjectTag')
                              || 0;

    my $result = $agent->trigger_event(
        dedup_key => $dedup_key,
        summary   => ($include_subject_tag
                         ? $self->TicketObj->SubjectTag . ' '
                         : ''
                     ) . $self->TicketObj->Subject,
        source    => $queue_service  || 'RT',
        severity  => $queue_priority || 'critical',
        class     => 'Ticket',
        links => [
            {
                href => RT->Config->Get('WebBaseURL') . '/' . $self->TicketObj->id,
                text => 'RT Ticket',
            },
        ],
    );

    return ($result, $@);
}

1;
