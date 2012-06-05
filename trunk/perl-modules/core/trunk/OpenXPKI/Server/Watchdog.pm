## OpenXPKI::Server::Watchdog.pm
##
## Written 2012 by Dieter Siebeck for the OpenXPKI project
## Copyright (C) 2012-20xx by The OpenXPKI Project

package OpenXPKI::Server::Watchdog;
use strict;
use English;
use OpenXPKI::Debug;
use OpenXPKI::Exception;
use OpenXPKI::Server::Session;
use OpenXPKI::Server::Context qw( CTX );
use OpenXPKI::Server::Watchdog::WorkflowInstance;
use OpenXPKI::DateTime;

use Data::Dumper;

my $workflow_table = 'WORKFLOW';

my $max_fork_redo = 5;
my $max_exception_threshhold = 10;
my $max_tries_hanging_workflows = 3;
my $interval_wait_initial = 10;
my $interval_loop_idle = 5;#seconds
my $interval_between_searches = 1;#seconds

sub new {
    my $that = shift;
    my $class = ref($that) || $that;
    
    
    my $self = {};

    bless $self, $class;

    #these are the keys of OpenXPKI::Server::Init:
    my $keys = {@_};

    return $self;

}

sub run {
    my $self = shift;

    my $pid;
    my $redo_count = 0;
    
    while ( !defined $pid && $redo_count < $max_fork_redo ) {
        ##! 16: 'trying to fork'
        $pid = fork();
        ##! 16: 'pid: ' . $pid
        if ( !defined $pid ) {
            if ( $!{EAGAIN} ) {

                # recoverable fork error
                sleep 2;
                $redo_count++;
            } else {

                # other fork error
                OpenXPKI::Exception->throw( message => 'I18N_OPENXPKI_SERVER_INIT_WATCHDOG_FORK_FAILED', );
            }
        }
    }
    if ( !defined $pid ) {
        OpenXPKI::Exception->throw( message => 'I18N_OPENXPKI_SERVER_INIT_WATCHDOG_FORK_FAILED', );
    } elsif ( $pid != 0 ) {
        ##! 16: 'parent here'
        ##! 16: 'parent: process group: ' . getpgrp(0)
        # we have forked successfully and have nothing to do any more except for getting a new database handle
            CTX('dbi_log')->new_dbh();
            ##! 16: 'new parent dbi_log dbh'
            CTX('dbi_workflow')->new_dbh();
            ##! 16: 'new parent dbi_workflow dbh'
            CTX('dbi_backend')->new_dbh();
            ##! 16: 'new parent dbi_backend dbh'
            CTX('dbi_log')->connect();
            CTX('dbi_workflow')->connect();
            CTX('dbi_backend')->connect();
            # get new database handles
            ##! 16: 'parent: DB handles reconnected'
            
    } else {
        ##! 16: 'child here'
        CTX('dbi_log')->new_dbh();
        ##! 16: 'new child dbi_log dbh'
        CTX('dbi_workflow')->new_dbh();
        ##! 16: 'new child dbi_workflow dbh'
        CTX('dbi_backend')->new_dbh();
        ##! 16: 'new child dbi_backend dbh'
        CTX('dbi_log')->connect();
        CTX('dbi_workflow')->connect();
        CTX('dbi_backend')->connect();
        ##! 16: 'child: DB handles reconnected'

        $self->{dbi}                      = CTX('dbi_workflow');
        $self->{hanging_workflows}        = {};
        $self->{hanging_workflows_warned} = {};
        $self->{original_pid}             = $PID;
        

        # append fork info to process name
        $0 .= ' watchdog (forked daemon)';

        #wait some time for server startup...
        ##! 16: sprintf('watchdog: original PID %d, initail wait for %d seconds', $self->{original_pid} , $interval_wait_initial);
        sleep($interval_wait_initial);

        ### TODO: maybe we should measure the count of exception in a certain time interval?
        my $exception_count = 0;
        
        while (1) {
            
            ##! 80: 'watchdog: start loop'
            ##! 4: '.'
            #ensure that we have a valid session
            $self->__check_session();
            
            eval { $self->_scan_for_paused_workflows(); };
            my $error_msg;
            if ( my $exc = OpenXPKI::Exception->caught() ) {
                $exc->show_trace(1);
                $error_msg = "Watchdog, fatal exception: $exc";
            } elsif ($EVAL_ERROR) {
                $error_msg = "Watchdog, fatal error: " . $EVAL_ERROR;
            }
            if ($error_msg) {
                CTX('log')->log(
                    MESSAGE  => $error_msg,
                    PRIORITY => "fatal",
                    FACILITY => "system"
                );

                print STDERR $error_msg, "\n";
                $exception_count++;
            }
            if ( $exception_count > $max_exception_threshhold ) {
                my $msg = "Watchdog: max exception limit reached: $max_exception_threshhold errors, exit watchdog!";
                CTX('log')->log(
                    MESSAGE  => $msg,
                    PRIORITY => "fatal",
                    FACILITY => "system"
                );

                print STDERR $msg, "\n";
                exit;
            }

            ##! 80: sprintf('watchdog sleeps %d secs',$interval_loop_idle)
            sleep($interval_loop_idle);

        }

    }

    sub _scan_for_paused_workflows {
        my $self = shift;

        #search ONE paused workflow

        # commit to get a current snapshot of the database in the highest isolation level.
        $self->{dbi}->commit();

        #fetch paused workflows:
        my $db_result = $self->__fetch_paused_workflows();

        if ( !defined $db_result ) {
            #check, if an entry exists, which marked from another watchdog, but not updated since 1 minute
            $db_result = $self->_fetch_and_check_for_orphaned_workflows();
        }

        if ( !defined $db_result ) {
            ##! 80: 'no paused WF found, can be idle again...'
            return;
        }

        ##! 16: 'found paused workflow: '.Dumper($db_result)

        # we need to be VERY sure, that no other process simultaneously takes this workflow and tries to execute it
        # hence we generate a random key to mark this workflow as "mine"
        my $rand_key = $self->__gen_key();

        my $wf_id   = $db_result->{WORKFLOW_SERIAL};
        my $old_key = $db_result->{WATCHDOG_KEY};

        my $update_ok = $self->__flag_wf_with_watchdog_mark( $wf_id, $rand_key, $old_key );
        if ( !$update_ok ) {
            ##! 16: 'watchdog mark could not be set, return '
            return;
        }

        #select again:
        my $db_result = $self->__fetch_marked_workflow_again( $wf_id, $rand_key );
        if ( !defined $db_result ) {
            ##! 16: sprintf('some other process took wf %s, return',$wf_id)
            return;
        }

        ##! 16: 'WF now ready to re-instantiate: '.Dumper($db_result)
        CTX('log')->log(
            MESSAGE  => sprintf( 'watchdog, paused wf %d now ready to re-instantiate, start fork process', $wf_id ),
            PRIORITY => "info",
            FACILITY => "workflow",
        );
        $self->{dbi}->commit();
        
        eval{
            my $Instance = OpenXPKI::Server::Watchdog::WorkflowInstance->new();
            $Instance->run($db_result);
        };
        my $error_msg;
        if ( my $exc = OpenXPKI::Exception->caught() ) {
            $exc->show_trace(1);
            $error_msg = "Exception caught while forking child instance: $exc";
        } elsif ($EVAL_ERROR) {
            $error_msg = "Fatal error while forking child instance:" . $EVAL_ERROR;
        }
        if ($error_msg) {
            CTX('log')->log(
                MESSAGE  => $error_msg,
                PRIORITY => "fatal",
                FACILITY => "workflow"
            );
        }
        
        #for child processes no further than here!
        if($self->{original_pid} ne $PID){
            ##! 16: sprintf('exit this process: actual pid %s is not original pid %s' , $PID, $self->{original_pid});
            exit;
        }
        
        #if we have found a workflow, we sleep a bit and search another paused wf
        sleep($interval_between_searches);
        $self->_scan_for_paused_workflows();
    }

    

    sub __fetch_marked_workflow_again {
        my $self = shift;
        my ( $wf_id, $rand_key ) = @_;
        my $db_result = $self->{dbi}->first(
            TABLE   => $workflow_table,
            COLUMNS => ['WORKFLOW_SERIAL'],
            DYNAMIC => {
                'WORKFLOW_PROC_STATE' => { VALUE => 'pause' },
                'WATCHDOG_KEY'        => { VALUE => $rand_key },
                'WORKFLOW_SERIAL'     => { VALUE => $wf_id },
            },
        );

        unless ( defined $db_result ) {
            CTX('log')->log(
                MESSAGE  => sprintf( 'watchdog, refetching wf %d with mark "%s" not succesfull', $wf_id, $rand_key ),
                PRIORITY => "info",
                FACILITY => "workflow",
            );
        }

        return $db_result;
    }

    sub __flag_wf_with_watchdog_mark {
        my $self = shift;
        my ( $wf_id, $rand_key, $old_key ) = @_;

        return unless $wf_id;    #this is real defensive programming ...;-)

        ##! 16: 'set random key '.$rand_key

        CTX('log')->log(
            MESSAGE  => sprintf( 'watchdog: paused wf %d found, mark with flag "%s"', $wf_id, $rand_key ),
            PRIORITY => "info",
            FACILITY => "workflow",
        );

        # it is necessary to explicitely set WORKFLOW_LAST_UPDATE,
        # because otherwise ON UPDATE CURRENT_TIMESTAMP will set (maybe) a non UTC timestamp
        my $now = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');
        # watchdog key will be reseted automatically, when the workflow is updated from within 
        # the API (via factory::save_workflow()), which happens immediately, when the action is executed
        # (see OpenXPKI::Server::Workflow::Persister::DBI::update_workflow())
        my $update_ok = $self->{dbi}->update(
            TABLE => $workflow_table,
            DATA  => { WATCHDOG_KEY => $rand_key, WATCHDOG_TIME => $now, WORKFLOW_LAST_UPDATE => $now },
            WHERE => {
                WATCHDOG_KEY        => $old_key,
                WORKFLOW_SERIAL     => $wf_id,
                WORKFLOW_PROC_STATE => 'pause'
            }
        );

        if ( !$update_ok ) {
            CTX('log')->log(
                MESSAGE  => sprintf( 'watchdog, paused wf %d: update with mark "%s" not succesfull', $wf_id, $rand_key ),
                PRIORITY => "info",
                FACILITY => "workflow",
            );
        }
        return $update_ok;
    }

    sub __fetch_paused_workflows {
        my $self = shift;
        my $now  = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');

        return $self->{dbi}->first(
            TABLE   => $workflow_table,
            COLUMNS => ['WORKFLOW_SERIAL'],
            DYNAMIC => {
                'WORKFLOW_PROC_STATE' => { VALUE => 'pause' },
                'WATCHDOG_KEY'        => { VALUE => '' },
                'WORKFLOW_WAKEUP_AT'  => { VALUE => $now, OPERATOR => 'LESS_THAN' },
            },
        );
    }

    sub _fetch_and_check_for_orphaned_workflows {
        my $self = shift;
        my $now  = DateTime->now->strftime('%Y-%m-%d %H:%M:%S');

        my $time_diff = OpenXPKI::DateTime::get_validity(
            {
                VALIDITY       => '-0000000001',#should be one minute old
                VALIDITYFORMAT => 'relativedate',
            },
        )->datetime();

        my $db_result = $self->{dbi}->first(
            TABLE   => $workflow_table,
            COLUMNS => ['WORKFLOW_SERIAL'],
            DYNAMIC => {
                'WORKFLOW_PROC_STATE' => { VALUE => 'pause' },
                'WATCHDOG_KEY'        => { VALUE => '', OPERATOR => 'NOT_EQUAL' },
                'WATCHDOG_TIME'       => { VALUE => $time_diff, OPERATOR => 'LESS_THAN' },
                'WORKFLOW_WAKEUP_AT'  => { VALUE => $now, OPERATOR => 'LESS_THAN' },
            },
        );

        if ( defined $db_result ) {
            ##! 16: 'found not processed workflow from another watchdog-call: '.Dumper($db_result)
            my $wf_id = $db_result->{WORKFLOW_SERIAL};

            $self->{hanging_workflows}{$wf_id}++;
            if ( $self->{hanging_workflows}{$wf_id} > $max_tries_hanging_workflows) {
                ##! 16: 'hanged to often!'

                $db_result = undef;
                unless ( $self->{hanging_workflows_warned}{$wf_id} ) {
                    CTX('log')->log(
                        MESSAGE => sprintf(
                            'watchdog meets hanging wf %d for %dth time, will not try to take over again',
                            $wf_id, $self->{hanging_workflows}{$wf_id}
                        ),
                        PRIORITY => "fatal",
                        FACILITY => "workflow",
                    );
                    $self->{hanging_workflows_warned}{$wf_id} = 1;
                }

                return;
            } else {
                CTX('log')->log(
                    MESSAGE  => sprintf( 'watchdog: hanging wf %d found, try to take over!', $wf_id ),
                    PRIORITY => "info",
                    FACILITY => "workflow",
                );
            }
        }

        return $db_result;

    }
    
    sub __check_session{
        #my $self = shift;
        my $session;
        eval{
           $session = CTX('session');
        };
        if($session ){
            return;
        }
        ##! 4: "create new session"
        $session = OpenXPKI::Server::Session->new({
                       DIRECTORY => CTX('xml_config')->get_xpath(XPATH => "common/server/session_dir"),
                       LIFETIME  => CTX('xml_config')->get_xpath(XPATH => "common/server/session_lifetime"),
       });
       OpenXPKI::Server::Context::setcontext({'session' => $session});
       ##! 4: sprintf(" session %d created" , $session->get_id()) 
    }
    
    
    sub __gen_key {

        #my $self = shift;
        return sprintf( '%s_%s_%s', $PID, time(), sprintf( '%02.d', rand(100) ) );
    }
}

1;
