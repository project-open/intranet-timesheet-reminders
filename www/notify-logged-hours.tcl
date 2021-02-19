# /packages/intranet-reporting/www/notify-logged-hours.tcl
#
# Copyright (C) 1998 - now Project Open Business Solutions S.L. 

# All rights reserved. Please check
# https://www.project-open.com/ for licensing details.

ad_page_contract {
    Purpose: Allows sending an email reminder 
    @author klaus.hofeditz@project-open.com
} {
    user_id:array,optional
    start_date 
    end_date 
    { return_url "" }
}

#-------------------------
# Defaults and Constants 
#-------------------------

set current_user_id [ad_maybe_redirect_for_registration]
db_0or1row get_name_current_user "select first_names, last_name from persons where person_id=:current_user_id"
set list_name_recipient [list]

#-------------------------
# Form validation
#-------------------------
if { ![info exists user_id] } {
    ad_return_complaint 1 [lang::message::lookup "" intranet-timesheet-reminders.MissingUserId "To send a reminder email, please select at least one user."]
}

#-------------------------
# Security 
#-------------------------

# Check if all user_id are direct reports of current user and set name_recipient at the same time 
# No other permissions checks will be performed
set direct_reports [db_list get_direct_reports "select employee_id from im_employees e, registered_users u where e.employee_id = u.user_id and e.supervisor_id = $current_user_id" ]
foreach rec_user_id [array names user_id] {
    if { [lindex $direct_reports $rec_user_id] == -1 } {
	ad_return_complaint 1 [lang::message::lookup "" intranet-reporting.UserNotADirectReport "We found a user that is not one of your direct reports, please go back and correct the error."]
    }  
    # Can be done more efficient ....
    set user_email [db_string get_user_email "select email from parties where party_id=:rec_user_id" -default ""]  
    lappend list_name_recipient "[im_name_from_user_id $rec_user_id]&nbsp;&lt;$user_email&gt;"
}

# --------------------------------------------------------
# Prepare to send out an email alert
# --------------------------------------------------------

set page_title [lang::message::lookup "" intranet-timesheet-reminders.SendEmailReminder "Send email Reminder"]
set context [list $page_title]
set export_vars [export_vars -form {return_url user_id:multiple start_date end_date}]
set name_recipient [join $list_name_recipient ", "]

# Show a textarea to edit the alert at member-add-2.tcl
ad_return_template

