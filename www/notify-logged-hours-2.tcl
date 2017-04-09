# /packages/intranet-reporting/www/member-notify.tcl
#
# Copyright (C) 1998 - now Project Open Business Solutions S.L.
# All rights reserved. Please check

# http://www.project-open.com/ for licensing details.


ad_page_contract {
    Sends an email with an attachment to a user

    @param user_id_from_search A user id
    @subject A subject line
    @message A message that can be either plain text or html
    @message_mime_type "text/plain" or "text/html"
    @send_me_a_copy Should be different from "" in order to send a copy to the sender.
    @return_url Where whould the script go after finishing its task?

    @author Frank Bergmann
    @author Klaus Hofeditz 

} {
    { subject:notnull "Subject" }
    { message:allhtml "Message" }
    { message_mime_type "text/plain" }
    { send_me_a_copy "" }
    user_id:array,optional
    return_url
    { process_mail_queue_now_p 1}
    { from_email ""}
    { start_date "" }
    { end_date "" }
    { test_mode_p 0 }
}

ns_log Notice "subject='$subject'"
ns_log Notice "message_mime_type='$message_mime_type'"
ns_log Notice "send_me_a_copy='$send_me_a_copy'"
ns_log Notice "return_url='$return_url'"
ns_log Notice "process_mail_queue_now_p='$process_mail_queue_now_p'"
ns_log Notice "message='$message'"

# ---------------------------------------------------------------
# Defaults & Security
# ---------------------------------------------------------------

set current_user_id [ad_maybe_redirect_for_registration]
set ip_addr [ad_conn peeraddr]
set locale [ad_conn locale]
set creation_ip [ad_conn peeraddr]
set time_date [im_exec date "+%s.%N"]
set add_ts_record_to_reminders_p [parameter::get -package_id [apm_package_id_from_key intranet-reporting] -parameter "AddTSRecordToReminders" -default 1]
set test_output ""

# Check if all user_id are direct reports of current user and set name_recipient at the same time
set direct_reports [db_list get_direct_reports "select employee_id from im_employees e, registered_users u where e.employee_id = u.user_id and e.supervisor_id = $current_user_id and u.member_state = 'approved'" ]
foreach rec_user_id [array names user_id] {
    if { [lindex $direct_reports $rec_user_id] == -1 } {
        ad_return_complaint 1 [lang::message::lookup "" intranet-reporting.UserNotADirectReport "We found a user that is not one of your direct reports, please go back and correct the error."]
    }
    lappend list_name_recipient [im_name_from_user_id $rec_user_id]
}

# Determine the sender address
set sender_email [parameter::get -package_id [apm_package_id_from_key acs-kernel] -parameter "SystemOwner" -default ""]
catch {set sender_email [db_string sender_email "select email as sender_email from parties where party_id = :current_user_id" -default $sender_email]}
if { "" == $sender_email } { ad_return_complaint 1 [lang::message::lookup "" intranet-reporting.CantEvaluateSenderEmail "Can't evaluate Sender email, please contact your System Administrator"] }

# ---------------------------------------------------------------
# Send to whom?
# ---------------------------------------------------------------

# Get user list and email list
set sql "
        select
                p.party_id,
                p.email,
                coalesce(e.availability,100) as availability
        from
                parties p,
                im_employees e
        where
                party_id in ([join [array names user_id] ","]) and
                p.party_id = e.employee_id
"

set email_list [db_list_of_lists email_list $sql]

# Include a copy to myself?
# if {"" != $send_me_a_copy} {
#    lappend email_list [db_string user_email "select email from parties where party_id = :current_user_id"]
# }

# ---------------------------------------------------------------
# Create the message and send it right away 
# ---------------------------------------------------------------

# Trim the subject. Otherwise we'll get MIME-garbage
set subject [string trim $subject]

# send to contacts
foreach rec $email_list {

    # TS data can only be added when start and end date is provided
    if { "" != $start_date && "" != $end_date } {

	set user_ts_data_for_period [im_user_absences_hours_accounted_for [lindex $rec 0] [lindex $rec 2] $start_date $end_date]
        set hours_logged [lindex $user_ts_data_for_period 1]
        set target_hours [lindex $user_ts_data_for_period 0]
        set hours_absences [lindex $user_ts_data_for_period 2]
        set absence_str [lindex $user_ts_data_for_period 3]

	if {[catch {
	    set difference_hours "[expr $target_hours - $hours_absences - $hours_logged]&nbsp;[lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]"
	} err_msg]} {
	    set difference_hours [lang::message::lookup "" intranet-timesheet-reminders.ErrorCalculatingDifference "Error calculating difference."]
	    global errorInfo
	    ns_log ERROR "Error intranet-timesheet-reminders/www/notify-logged-hours-2.tcl, error calculating difference_hours \n $errorInfo "    
	}

	if { $add_ts_record_to_reminders_p } {
	    set message "<pre style='font-family:verdana,arial,helvetica,sans-serif;'>$message</pre><br/> 
	        <table cellpadding=\"3\" cellspacing=\"3\" border=\"0\" style=\"border-collapse:collapse;\">
       		<tr>
                <td style=\"font-weight:bold;border: 1px solid grey;vertical-align:text-top;\">[lang::message::lookup "" intranet-timesheet2.Absences "Absences"]</td>
                <td style=\"font-weight:bold;border: 1px solid grey;vertical-align:text-top;\">[lang::message::lookup "" intranet-timesheet2.HoursLogged "Hours logged"]</td>
                <td style=\"font-weight:bold;border: 1px solid grey;vertical-align:text-top;\">[lang::message::lookup "" intranet-timesheet2.Target "Target"]</td>
                <td style=\"font-weight:bold;border: 1px solid grey;vertical-align:text-top;\">[lang::message::lookup "" intranet-core.Difference "Difference"]</td>
        	</tr>
                <tr>
                <td style=\"border: 1px solid grey;vertical-align:text-top;\">$hours_absences [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]</td>
                <td style=\"border: 1px solid grey;vertical-align:text-top;\">$hours_logged [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]</td>
                <td style=\"border: 1px solid grey;vertical-align:text-top;\">$target_hours [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]</td>
                <td style=\"border: 1px solid grey;vertical-align:text-top;\">$difference_hours</td>
                </tr>
		</table>
	   "
	}    
    }

    if {[catch {
	if { !$test_mode_p } {
	    acs_mail_lite::send \
		-send_immediately \
		-to_addr [lindex $rec 1] \
		-from_addr $sender_email \
		-subject $subject \
		-body $message \
                -extraheaders "" \
                -mime_type "text/html"
	} else {
	    append test_output "to_addr: [lindex $rec 1]<br>from_addr: $sender_email<br>subject: $subject<br>message: $message <br>*******<br>"
	} 
    } errmsg]} {
        ns_log Error "member-notify: Error sending to \"$sender_email\": $errmsg"
	ad_return_error $subject "<p>Error sending out mail:</p><div><code>[ad_quotehtml $errmsg]</code></div>"
	ad_script_abort
    }
}

# ---------------------------------------------------------------
# This page has no confirmation screen
# ---------------------------------------------------------------
if { !$test_mode_p } {
    ad_returnredirect $return_url
} else {
    ns_return 1 text/html $test_output
}

