# /packages/intranet-timesheet-reminders/tcl/intranet-timesheet-reminders-procs.tcl
#
# Copyright (C) 2013-now Project Open Business Solutions S.L. 
#
# All rights reserved. Please check
# http://www.project-open.com/license/ for details.

ad_library {
    @author klaus.hofeditz@project-open.com
}

ad_proc -public im_timesheet_scheduled_reminders_send { } {
} {

    # This function will be excecuted by default every hour.  
    # In order to ensure the sending of email reminders under most circumstances, 
    # such as changing of server time, system outage etc., we go back as much as 
    # 24 hours to look for due time intervals and check if they have been treated. 

    # Set-off allows a delay for geographically distributed organizations.  
    # Example: 
    # Server location/server time is Australia. For weekly reminders the 
    # preconfigured time is saturday noon.
    # Staff working in the Berlin Office should have logged their hours by this time as it's 
    # 2am in the morning. People on the west cost however might not have logged their 
    # hours yet for friday as it's only 5pm there.      

    set interval [parameter::get -package_id [apm_package_id_from_key intranet-timesheet-reminders] -parameter "Interval" -default "monthly"]
    set set_off [parameter::get -package_id [apm_package_id_from_key intranet-timesheet-reminders] -parameter "SetOff" -default 0]

    # Consider all timespans of the last 24h. This way we limit the amount of emails that will be send out in case of an application or configuration error. 
    # By substracting the 'set-off' we simulate an earlier date 

    if {[catch {
	set frame_start_date [clock format [expr [clock seconds] - $set_off] -format "%Y-%m-%d %H:%M:%S"]    
	ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_scheduled_reminders_send frame_start_date: $frame_start_date"
    } err_msg]} {
	global errorInfo
	ns_log Error "Error in intranet-timesheet-reminders-procs.tcl - Not able to calculate start_date.\n $errorInfo "
	db_dml im_timesheet_reminders_stats "insert into im_timesheet_reminders_stats (event_id, triggered,timespan_found_p,notes) values (null, now(),0,'Error calculating start_date, $errorInfo')"
	return
    }
    set frame_end_date [clock format [clock scan {-24 hours} -base [clock scan $frame_start_date] ] -format "%Y-%m-%d %H:%M:%S"]
    ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_scheduled_reminders_send - Search events using frame_start_date: $frame_start_date, frame_end_date: $frame_end_date"

    set sql "
	select 
		to_char(i.start_date,'yyyy-mm-dd HH24:MI') as start_date,
		e.name,
		e.event_id,
		i.interval_id
	from 
		acs_events e, 
		timespans t,
		time_intervals i
	where 
		t.interval_id = i.interval_id 
		and e.timespan_id = t.timespan_id
		and i.start_date between :frame_end_date and :frame_start_date
		and (e.name = 'Weekly Email Reminders' OR e.name = 'Monthly Email Reminders') 
		and e.event_id not in (select event_id from im_timesheet_reminders_stats where timespan_found_p is true) 
    " 

    set period_list [list]

    db_foreach r $sql {
	 ns_log NOTICE "--- LP: intranet-timesheet-reminders-procs::im_timesheet_scheduled_reminders_send start_date: $start_date, name: $name, event_id: $event_id, interval_id: $interval_id"
	# Calcluate period 
	if { "Weekly Email Reminders" == $name } {
	    # Hours from the last 7 days, starting start_date-1  
	    set period_start_date [clock format [clock scan {-7 days} -base [clock scan $start_date] ] -format "%Y-%m-%d %H:%M:%S"] 
	    set period_end_date [clock format [clock scan {-1 days} -base [clock scan $start_date] ] -format "%Y-%m-%d %H:%M:%S"]
	    ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_scheduled_reminders_send - 'Weekly Email Reminder' period_start_date: $period_start_date, period_end_date: $period_end_date"    
	} else {
	    # Monthly reminders - Hours for last month 
	    set period_start_date [clock format [clock scan {-1 month} -base [clock scan $start_date] ] -format "%Y-%m-%d %H:%M:%S"]
	    set period_end_date [clock format [clock scan {-1 day} -base [clock scan $start_date] ] -format "%Y-%m-%d %H:%M:%S"]   
            ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_scheduled_reminders_send - 'Monthly Email Reminder' period_start_date: $period_start_date, period_end_date: $period_end_date"
	}
	lappend period_list [list $period_start_date $period_end_date $interval_id $event_id]
    }

    # Prevent spamming - avoid sending multiple reminders when more than one period is found 
    if { 0 == [llength $period_list] } {
	ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_scheduled_reminders_send - No events found"
        set note_no_events "No events found. Period looked up: $frame_end_date - $frame_start_date"
        db_dml im_timesheet_reminders_stats "insert into im_timesheet_reminders_stats (event_id, triggered, timespan_found_p, notes) values (null, now(), false, :note_no_events)"
    } else {
	# Send for first period found
	ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_scheduled_reminders_send - Sending first element of period_list: $period_list" 
	set send_protocol [im_timesheet_send_reminders_to_supervisors [lindex [lindex $period_list 0] 0] [lindex [lindex $period_list 0] 1] 0]
	set event_id_send [lindex [lindex $period_list 0] 3]
	db_dml im_timesheet_reminders_stats "insert into im_timesheet_reminders_stats (event_id, triggered, timespan_found_p, notes) values (:event_id_send, now(), true, :send_protocol)"

	# Keep track of all interval_id's no reminder had been sent for and mark them
	set period_list [lreplace $period_list 0 0]; # Remove element already handled
	foreach element $period_list {
	    db_dml im_timesheet_reminders_stats "insert into im_timesheet_reminders_stats (event_id, triggered, timespan_found_p, notes) values ([lindex $element 3], now(), true, 'skipped, reminder already send (event_id: $event_id_send)')"
	}
    }
}

ad_proc -public im_timesheet_send_reminders_to_supervisors {
    period_start_date
    period_end_date
    do_not_send_email_p
    
} {
    Sends email reminders to supervisors
} {

    # Make sure that date format is YYYY-MM-DD
    set period_start_date [clock format [clock scan $period_start_date] -format {%Y-%m-%d}]
    set period_end_date [clock format [clock scan $period_end_date] -format {%Y-%m-%d}]

    set send_protocol "<h1>Mail Protocol for TS Reminders</h1>Start Date: $period_start_date <br>End Date: $period_end_date"

    ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_to_supervisors ENTERING" 
    set from_email [parameter::get -package_id [apm_package_id_from_key acs-kernel] -parameter "HostAdministrator" -default ""]

    # get all active employees; add dummy record for easy looping  
    set sql "
    select 
    	e.supervisor_id as manager_id,
	im_name_from_user_id(e.supervisor_id) as manager_name,
	im_email_from_user_id(e.supervisor_id) as manager_email,
	acs_lang_get_locale_for_user(e.supervisor_id) as manager_locale,
	e.employee_id,
	coalesce(e.availability,100) as availability,
	im_name_from_user_id(e.employee_id) as employee_name
    from
	im_employees e,
	cc_users u
    where
	e.employee_id = u.user_id 
	and u.member_state = 'approved' 
	and e.supervisor_id IS NOT NULL
    UNION
	select
		999999999 as manager_id,
		'' as manager_name,
		'' as manager_email,
		'' as manager_locale,
		999999999 as employee_id,
		0 as availability,
		'' as employee_name
	from dual
    order by
    	  manager_id; 
    "
    set old_manager_id -1
    set old_manager_email ""
    set mail_body ""

    db_foreach r $sql {
	if { -1 != $old_manager_id && $old_manager_id != "999999999" } {
	    # Check for change of manager_id 
	    if { $manager_id != $old_manager_id } {

		ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_to_supervisors: ------------------------------------------------------------------------ "
		ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_to_supervisors: ---- NEW MANAGER FOUND: $manager_name / Old: $old_manager_email "
		ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_to_supervisors: ------------------------------------------------------------------------ "
		ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_to_supervisors: Sending mail to: $old_manager_email; mail_body_user_records: [array get mail_body_user_records]"

		# build mail_body 
		set mail_body [im_timesheet_send_reminders_build_mailbody $period_start_date $period_end_date $manager_id $manager_name $manager_locale [array get mail_body_user_records]]

		if { !$do_not_send_email_p } {
		    acs_mail_lite::send \
			-send_immediately \
			-to_addr $old_manager_email \
			-from_addr $from_email \
			-subject  "[lang::message::lookup "" intranet-timesheet-reminders.ReminderSubjectWeeklyReminder "Weekly TS Reminder"]: $period_start_date - $period_end_date" \
			-body $mail_body \
			-extraheaders "" \
			-mime_type "text/html"
		} 

		# Write protocol
		append send_protocol "<br><br><h2>Email to: $old_manager_email:$mail_body</h2> <br><br>"

		# reset manager_id & email 
		set old_manager_id $manager_id
		set old_manager_email $manager_email
		
		# reset array user records  
		array unset mail_body_user_records

	    }
	} else {
	    set old_manager_id $manager_id
	    set old_manager_email $manager_email
	}
	
	ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_to_supervisors: Now evaluating: manager_name: $manager_name, employee_name: $employee_name"

	# Get amount of hours accounted for 
	if { [info exists mail_body_user_records($employee_id)] } {
	    lappend mail_body_user_records($employee_id) [list $employee_name [im_user_absences_hours_accounted_for $employee_id $availability $period_start_date $period_end_date]] 
	} else {
	    set mail_body_user_records($employee_id) [list $employee_name [im_user_absences_hours_accounted_for $employee_id $availability $period_start_date $period_end_date]]
	}
	ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_to_supervisors: mail_body_user_records($employee_id): $mail_body_user_records($employee_id)"
    }

    ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_to_supervisors LEAVING"
    if { !$do_not_send_email_p } {
	return $send_protocol
    } else {
	ns_return 1 text/html $send_protocol
    }
}

# This function should become part of the TS Module 
ad_proc -public im_user_absences_hours_accounted_for {
    employee_id
    availability
    period_start_date
    period_end_date 
} {
    Returns list with three items: 

    Target Hours: 	Number of workdays * Availability * TimesheetHoursPerDay  
    Hours logged:	Hours logged
    Hours Absences:  	Hours covered by personal or group absences 
    
} {

    set system_url [parameter::get -package_id [apm_package_id_from_key acs-kernel] -parameter "SystemURL" -default ""]
    set hours_per_day [parameter::get -package_id [apm_package_id_from_key intranet-timesheet2] -parameter "TimesheetHoursPerDay" -default 8]

    ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: ENTER ----- Employee: [im_name_from_user_id $employee_id] ------------------ "

    # -----------------------------------------------
    # Hours logged 
    # -----------------------------------------------
  
    set sql " 
    	select
		coalesce(sum(hours),0)
	from
		im_hours h,
		im_projects p,
		im_projects main_p,
		im_companies c,
		users u 
	where
		h.project_id = p.project_id
		and main_p.project_status_id not in (82)
		and h.user_id = u.user_id
		and main_p.tree_sortkey = tree_root_key(p.tree_sortkey)
		and h.day >= to_timestamp(:period_start_date, 'YYYY-MM-DD')
		and h.day < to_timestamp(:period_end_date, 'YYYY-MM-DD')
		and main_p.company_id = c.company_id
		and h.user_id = :employee_id
    " 
    
    set hours_logged [db_string get_sum_hours_logged $sql -default 0]

    ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: hours logged: $hours_logged"

    # -----------------------------------------------
    # Absences
    # -----------------------------------------------

    # Handling of special cases: 
    #	- User with 50% availability
    #   - In period: 
    # 		- Bank Holiday (im_absences_get_absences_for_user_duration will return 1.0)
    #               - not an issue as for all employees the value will be the same 
    #   	- Other absences, e.g. "sick" (complete day) 
    #               - Employee might have entered 0.5 (half a day) or 1 day  
    #   	- Other absences, e.g. "sick" (partly) 
    #               - Effective duration expected  
    #           - Combination of absences 
    #               - Bank holiday during vacation 
   
    set hours_accounted_for_absences 0
    set absences_str "" 
    set sql "
		select 
			*,
			to_char(absence_date,'D') as dow 
		from 
			im_absences_get_absences_for_user_duration(:employee_id, :period_start_date, :period_end_date, null) AS 
			(absence_date date, absence_type_id int, absence_id int, duration_days numeric)
		where 
			to_char(absence_date,'D') <> '1' and 
			to_char(absence_date,'D') <> '7'
	" 
    db_foreach r $sql {
        # Build href string
        set duration_days_pretty [lc_numeric $duration_days "%.2f" [lang::user::locale]]
        append absences_str "<a href='${system_url}intranet-timesheet2/absences/new?form_mode=display&absence_id=$absence_id'>[im_category_from_id $absence_type_id]</a>: $duration_days_pretty [lang::message::lookup "" intranet-timesheet-reminders.Days "day(s)"]</a><br>"

	# Evaluate hours to add 
        # if { $absence_type_id == [im_user_absence_type_bank_holiday] || $absence_type_id == [im_user_absence_type_vacation] } {
        #    # Daily absences
	#    ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: Daily absence ($absence_date): [im_category_from_id $absence_type_id]: $duration_days"
        #    set hours_to_add [expr $hours_accounted_for_absences + [expr $hours_per_day * ($availability/100)]]
        # } else {
        #    # Effective duration
	#    ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: Effective absence ($absence_date): [im_category_from_id $absence_type_id]: $duration_days"
        #    set hours_to_add [expr $hours_per_day * $duration_days]
        # }

	set hours_to_add [expr $hours_per_day * $duration_days]

	# Handle multiple absences per day 
	if { [info exists absence_array($absence_date)] } {
	    set absence_array($absence_date) [expr $absence_array($absence_date) + $hours_to_add]
            ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: absence_array($absence_date): $absence_array($absence_date)"
	    # Avoid absences > 1 day 
	    # if { $absence_array($absence_date) > 1 } { 
	    #	ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: Now cutting total absence down to '1' -  absence_array($absence_date: $absence_array($absence_date)" 
	    #	set absence_array($absence_date) 1 
	    # }
	} else {
	    set absence_array($absence_date) $hours_to_add 
	    ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: New absence: absence_array($absence_date): $absence_array($absence_date)"
	}
    }
    
    # Accumulate values 
    foreach {key value} [array get absence_array] {
	set hours_accounted_for_absences [expr $hours_accounted_for_absences + $value]
    }

    set working_days [db_string get_data "select count(*) from im_absences_working_days_period_weekend_only (:period_start_date, :period_end_date) as (weekend_date date)" -default 0]
 
    # Hours w/o absences 
    set hours_target [expr ($hours_per_day * ([expr {double(round(1*$availability))}]/100.0)) * $working_days] 

    # Hours considering absences 
    # set hours_target [expr $hours_target - $hours_accounted_for_absences]

    ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: Found: hours_target: $hours_target, hours_logged: $hours_logged hours_accounted_for_absences: $hours_accounted_for_absences"
    ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: LEAVE ----- Employee: [im_name_from_user_id $employee_id] ------------------ "

    return [list $hours_target $hours_logged $hours_accounted_for_absences $absences_str]
} 


ad_proc -public im_timesheet_send_reminders_build_mailbody {
    period_start_date 
    period_end_date 
    manager_id
    manager_name 
    manager_locale
    user_records_list
} {
    Creates mail body 
    user_records_list (TargetHours HoursLogged HoursAbsences) 
} {

    set system_url [parameter::get -package_id [apm_package_id_from_key acs-kernel] -parameter "SystemURL" -default ""]
    set link "/intranet-timesheet-reminders/timesheet-monthly-hours-absences"
    
    ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_build_mailbody: ENTERING period_start_date: $period_start_date, period_end_date: $period_end_date, manager_name: $manager_name"
    ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_build_mailbody: user_records_list: $user_records_list"
    
    set user_record_html ""
    set total_hours_target 0 
    set total_hours_logged 0 
    set total_hours_absences 0 
    set total_hours_and_absences 0
    set url_user_ids [list]

    # array set mail_body_user_records $user_records_list 
    foreach {key value} $user_records_list {

	ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_build_mailbody: value(0): [lindex $value 0] value(1): [lindex $value 1]"

	lappend url_user_ids $key
	set employee_name [lindex $value 0]

	# Clearity before efficiency 
	set hours [lindex $value 1]

	set hours_logged [lindex $hours 1]
	set hours_target [lindex $hours 0]
        set hours_absences [lindex $hours 2]
       
	set absence_str [lindex $hours 3]
	set hours_and_absences [expr $hours_absences + $hours_logged] 
	set diff [expr ($hours_absences + $hours_logged) - $hours_target]

	set total_hours_logged [expr $total_hours_logged + $hours_logged]
	set total_hours_target [expr $total_hours_target + $hours_target]
	set total_hours_absences [expr $total_hours_absences + $hours_absences]
	set total_hours_and_absences [expr $total_hours_and_absences + $hours_logged + $hours_absences]

	# Formating 
	set hours_logged [lc_numeric $hours_logged "%.2f" $manager_locale]
	set hours_target [lc_numeric $hours_target "%.2f" $manager_locale]
	set hours_absences [lc_numeric $hours_absences "%.2f" $manager_locale]
	set hours_and_absences [lc_numeric $hours_and_absences "%.2f" $manager_locale]

        set diff [lc_numeric $diff "%.2f" $manager_locale]
	if { $diff < 0 } { 
	    set diff "<span style='color:red'>$diff [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]</span>" 
	} else {
	    set diff "$diff [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]"
	}

	set report_url "${system_url}intranet-timesheet-reminders/timesheet-monthly-hours-absences-reminder?user_id=$key&start_date=$period_start_date&end_date=$period_end_date"

	append user_record_html "
	       <tr>
		<td style=\"border: 1px solid grey;vertical-align:text-top;\">$employee_name</td>
		<td style=\"border: 1px solid grey;vertical-align:text-top;\">$absence_str</td>
		<td style=\"border: 1px solid grey;vertical-align:text-top;\" align=\"right\">$hours_absences [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]</td>
		<td style=\"border: 1px solid grey;vertical-align:text-top;\" align=\"right\">$hours_logged [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]</td>
		<td style=\"border: 1px solid grey;vertical-align:text-top;background-color:#EEE;\" align=\"right\">$hours_and_absences [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]</td>
		<td style=\"border: 1px solid grey;vertical-align:text-top;background-color:#EEE;\" align=\"right\">$hours_target [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]</td>
		<td style=\"border: 1px solid grey;vertical-align:text-top;\" align=\"right\">$diff</td>
		<td style=\"border: 1px solid grey;vertical-align:text-top;\"><a href='$report_url'>[lang::message::lookup "" intranet-timesheet-reminders.ViewDetails "View Details"]</a></td>
		</tr>"
    }

    set total_diff [expr ($total_hours_logged + $total_hours_absences) - $total_hours_target]

    # Formatting totals 
    set total_diff [lc_numeric $total_diff "%.2f" $manager_locale]
    if { $total_diff < 0 } { 
	set total_diff "<span style='color:red'>$total_diff [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]</span>" 
    } else {
	set total_diff "<span style='color:red'>$total_diff [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]</span>" 
    } 
    set total_hours_logged [lc_numeric $total_hours_logged "%.2f" $manager_locale]
    set total_hours_target [lc_numeric $total_hours_target "%.2f" $manager_locale]
    set total_hours_absences [lc_numeric $total_hours_absences "%.2f" $manager_locale]
    set total_hours_and_absences [lc_numeric $total_hours_and_absences "%.2f" $manager_locale]

    set url_all_users "${system_url}/intranet-timesheet-reminders/timesheet-monthly-hours-absences-reminder?user_id=[join $url_user_ids "&user_id="]&start_date=$period_start_date&end_date=$period_end_date"

    return "
    <html> 
    <head><meta charset=\"utf-8\"></head>
    <body>   
    <br/><br/>
    <!-- [lang::message::lookup "" intranet-timesheet-reminders.ReminderEmail "Hours logged for  %period_start_date% - %period_end_date%\n"]-->
    <table cellpadding=\"3\" cellspacing=\"3\" border=\"0\" style=\"border-collapse:collapse;\">
    	<tr>
		<td style=\"font-weight:bold;border: 1px solid grey;vertical-align:text-top;\">[lang::message::lookup "" intranet-core.EmployeeName "Employee Name"]</td>
    		<td style=\"font-weight:bold;border: 1px solid grey;vertical-align:text-top;\">[lang::message::lookup "" intranet-timesheet2.Absences "Absences"]</td>
    		<td style=\"font-weight:bold;border: 1px solid grey;vertical-align:text-top;\">[lang::message::lookup "" intranet-timesheet2.TotalAbsences_Break "Total<br>Absences"]</td>
		<td style=\"font-weight:bold;border: 1px solid grey;vertical-align:text-top;\">[lang::message::lookup "" intranet-timesheet2.HoursLogged "Logged"]</td>
		<td style=\"font-weight:bold;border: 1px solid grey;vertical-align:text-top;\">[lang::message::lookup "" intranet-timesheet-reminders.TotalAccountedFor "Total<br>accounted<br>for"]</td>
		<td style=\"font-weight:bold;border: 1px solid grey;vertical-align:text-top;\">[lang::message::lookup "" intranet-timesheet2.Target "Target"]</td>
		<td style=\"font-weight:bold;border: 1px solid grey;vertical-align:text-top;\">[lang::message::lookup "" intranet-core.Difference " Difference"]</td>
		<td style=\"font-weight:bold;border: 1px solid grey;vertical-align:text-top;\">[lang::message::lookup "" intranet-core.Links "Links"]</td>
	</tr>
        $user_record_html
	<tr>
		<td style=\"font-weight:bold;border: 1px solid grey;\">[lang::message::lookup "" intranet-timesheet-reminders.Total "Total"]</td>
		<td style=\"font-weight:bold;border: 1px solid grey;\">&nbsp;</td>
		<td style=\"font-weight:bold;border: 1px solid grey;\">&nbsp;</td>
		<td style=\"font-weight:bold;border: 1px solid grey;\" align=\"right\">$total_hours_logged [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]</td>
		<td style=\"font-weight:bold;border: 1px solid grey;background-color:#EEE;\" align=\"right\">$total_hours_and_absences [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]</td>
		<td style=\"font-weight:bold;border: 1px solid grey;background-color:#EEE;\" align=\"right\">$total_hours_target [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]</td>
		<td style=\"font-weight:bold;border: 1px solid grey;\" align=\"right\">$total_diff</td>
		<td style=\"font-weight:bold;border: 1px solid grey;\"><a href='$url_all_users'>[lang::message::lookup "" intranet-timesheet-reminder.ShowDetailsForAllUsers "Show details for all users"]</a></td>
	</tr>
     </table>
    </body>
    </html>
    "
    ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_build_mailbody: LEAVING"
}
