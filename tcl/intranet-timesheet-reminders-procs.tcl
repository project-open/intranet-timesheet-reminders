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

    # Consider all timespans of the last 24h 
    set frame_start_date [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    set frame_end_date [clock format [clock scan {-1 days} -base [clock scan $frame_start_date] ] -format "%Y-%m-%d %H:%M:%S"]

    # Check if reminders haven't been sent yet for events found  
    set sql "
	select 
		i.start_date,
		e.*
	from 
		acs_events e, 
		timespans t,
		time_intervals i,
		im_timesheet_reminders_stats stats
	where 
		t.interval_id = i.interval_id 
		and e.timespan_id = t.timespan_id
		and stats.event_id <> e.event_id 
		and i.start_date between :frame_start_date and :frame_end_date
		and e.event_id not in (select event_id from im_timesheet_reminders_stats) 
		and (e.name = 'Weekly Email Reminder' OR e.name = 'Monthly Email Reminder') 
    " 

    set ctr 0 
    db_foreach r $sql {

	# ToDo: Include a check for "set off" 

	# Calcluate period 
	if { "Weekly Email Reminder" == $name } {
	    # Hours from the last 7 days, starting start_date-1  
	    set period_start_date [clock format [clock scan {-1 days} -base [clock scan {$start_date}] ] -format "%Y-%m-%d"]
	    set period_end_date [clock format [clock scan {-8 days} -base [clock scan {$start_date}] ] -format "%Y-%m-%d"] 
	} else {
	    # Monthly reminders - Hours for last month 
	    set period_start_date [clock format [clock scan {-1 month} -base [clock scan {$start_date}] ] -format "%Y-%m-%d"]
	    set period_end_date [clock format [clock scan {-1 day} -base [clock scan {$start_date}] ] -format "%Y-%m-%d"] 	    
	}

	set send_protocol [im_timesheet_send_reminders_to_supervisors($period_start_date,$period_end_date)]
	db_dml im_timesheet_reminders_stats "insert into im_timesheet_reminders_stats (event_id, triggered, notes) values (:event_id, now(), $send_protocol)"
	incr ctr
    }

    # Write a rec to track execution 
    if { 0 == $ctr } {
	db_dml im_timesheet_reminders_stats "insert into im_timesheet_reminders_stats (event_id, triggered) values (null, now())"
    }
}

ad_proc -public im_timesheet_send_reminders_to_supervisors {
    period_start_date
    period_end_date
} {
    Sends email reminders to supervisors
} {

    set send_protocol "Start Date: $period_start_date, End date: $period_end_date:\n"

    ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_to_supervisors ENTERING" 
    set from_email [parameter::get -package_id [apm_package_id_from_key acs-kernel] -parameter "HostAdministrator" -default ""]

    # get all active employees, add dummy record for easy looping  
    set sql "
    	select distinct
	    m.manager_id,
	    im_name_from_user_id(m.manager_id) as manager_name,
	    im_email_from_user_id(m.manager_id) as manager_email,
            acs_lang_get_locale_for_user(m.manager_id) as manager_locale,
	    employee_id,
	    coalesce(e.availability,100) as availability,
	    im_name_from_user_id(e.employee_id) as employee_name
	 from
	     acs_objects o,
	     im_cost_centers m
	     LEFT JOIN (
	     	    select 
			e.*
		    from 
		    	im_employees e,
			cc_users u
	       	    where
			e.employee_id = u.user_id and
	       		u.member_state = 'approved'
	     ) e ON (e.department_id = m.cost_center_id)
	  where
	      o.object_id = m.cost_center_id
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
	      manager_id
    "

    set old_manager_id -1
    set old_manager_email ""
    set mail_body ""

    db_foreach r $sql {
	if { -1 != $old_manager_id } {
	    # Check for change of manager_id 
	    if { $manager_id != $old_manager_id } {
		ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_to_supervisors: ---- NEW MANAGER FOUND: $manager_name ---------- Old: $old_manager_email"
		ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_to_supervisors: Sending mail to: $old_manager_email; mail_body_user_records: [array get mail_body_user_records]"

		append send_protocol "$send_protocol, $old_manager_email"
		
		# build mail_body 
		set mail_body [im_timesheet_send_reminders_build_mailbody $period_start_date $period_end_date $manager_id $manager_name $manager_locale [array get mail_body_user_records]]

		# sending email 
		acs_mail_lite::send \
		    -send_immediately \
		    -to_addr $old_manager_email \
		    -from_addr $from_email \
		    -subject  "[lang::message::lookup "" intranet-timesheet-reminders.ReminderSubjectWeeklyReminder "Weekly TS Reminder"]: $period_start_date - $period_end_date" \
		    -body $mail_body \
		    -extraheaders "" \
		    -mime_type "text/html"

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
    return $send_protocol
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
    set sql "select * from im_absences_get_absences_for_user_duration(:employee_id, :period_start_date, :period_end_date, null) AS (absence_date date, absence_type_id int, absence_id int, duration_days numeric)" 

    set absences_str "" 
    db_foreach r $sql {
	# Build String 
	append absences_str "<a href='$system_url/intranet-timesheet2/absences/new?form_mode=display&absence_id=$absence_id'>[im_category_from_id $absence_type_id]</a>: $duration_days [lang::message::lookup "" intranet-timesheet-reminders.Days "day(s)"]</a><br>" 
	# Evaluate hours to add 
        if { $absence_type_id == [im_user_absence_type_bank_holiday] || $absence_type_id == [im_user_absence_type_vacation] } {
            # Daily absences
	    ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: Daily absence ($absence_date): [im_category_from_id $absence_type_id]: $duration_days"
            set hours_to_add [expr $hours_accounted_for_absences + [expr $hours_per_day * ($availability/100)]]
        } else {
            # Effective duration
	    ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: Effective absence ($absence_date): [im_category_from_id $absence_type_id]: $duration_days"
            set hours_to_add [expr $hours_per_day * $duration_days]
        }

	# Handle multiple absences per day 
	if { [info exists absence_array($absence_date)] } {
	    set absence_array($absence_date) [expr $absence_array($absence_date) + $hours_to_add]
            ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: absence_array($absence_date): $absence_array($absence_date)"
	    # Avoid absences > 1 day 
	    if { $absence_array($absence_date) > 1 } { 
		ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: Now cutting total absence down to '1' -  absence_array($absence_date: $absence_array($absence_date)" 
		set absence_array($absence_date) 1 
	    }
	} else {
	    set absence_array($absence_date) $hours_to_add 
	    ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: New absence: absence_array($absence_date): $absence_array($absence_date)"
	}
    }
    
    # Accumulate values 
    foreach {key value} [array get absence_array] {
	set hours_accounted_for_absences [expr $hours_accounted_for_absences + $value]
    }

    # Calculate target hours: 
    set working_days [db_string get_data "select count(*) from im_absences_working_days_period_weekend_only (:period_start_date, :period_end_date) as (weekend_date date)" -default 0]
    # Hours w/o absences 
    set target_hours [expr $hours_per_day * ($availability/100) * $working_days] 
    # Hours considering absences 
    # set target_hours [expr $target_hours - $hours_accounted_for_absences]

    ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: Found: target_hours: $target_hours, hours_logged: $hours_logged hours_accounted_for_absences: $hours_accounted_for_absences"

    return [list $target_hours $hours_logged $hours_accounted_for_absences $absences_str]

    ns_log NOTICE "intranet-timesheet-reminders-procs::im_user_absences_hours_accounted_for: LEAVE ----- Employee: [im_name_from_user_id $employee_id] ------------------ "
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
    set link "/intranet-reporting/timesheet-monthly-hours-absences"

    ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_build_mailbody: ENTERING period_start_date: $period_start_date, period_end_date: $period_end_date, manager_name: $manager_name"
    ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_build_mailbody: user_records_list: $user_records_list"
    
    set user_record_html ""
    set total_target_hours 0 
    set total_hours_logged 0 
    set total_hours_absences 0 

    # array set mail_body_user_records $user_records_list 
    foreach {key value} $user_records_list {

	ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_build_mailbody: value(0): [lindex $value 0] value(1): [lindex $value 1]"

	set employee_name [lindex $value 0]

	# Clearity before efficiency 
	set hours [lindex $value 1]

	set hours_logged [lindex $hours 1]
	set target_hours [lindex $hours 0]
        set hours_absences [lindex $hours 2]
        set absence_str [lindex $hours 3]

	set total_hours_logged [expr $total_hours_logged + $hours_logged]
	set total_target_hours [expr $total_target_hours + $target_hours]
	set total_hours_absences [expr $total_hours_absences + $hours_absences]

	set report_url "$system_url/intranet-reporting/timesheet-monthly-hours-absences-reminder?user_id=$key&$start_date=$period_start_date&$end_date=$period_end_date"

	append user_record_html "
	       <tr>
			<td>$employee_name</td>
			<td>$hours_absences [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]<br>$absence_str</td>
			<td>$hours_logged</td><td>$target_hours [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]</td>
			<td>[expr ($hours_absences + $hours_logged) - $target_hours] [lang::message::lookup "" intranet-timesheet-reminders.HoursAbrev "h"]</td>
			<td><a href='$report_url'>[lang::message::lookup "" intranet-timesheet-reminders.ViewDetails "View Details"]</a></td>
		</tr>"
    }

    set total_diff [expr ($total_hours_logged + $total_hours_absences) - $total_target_hours]

    return "
    <html> 
    <head><meta charset=\"utf-8\"></head>
    <body>   
    <br/><br/>
    <!-- [lang::message::lookup "" intranet-timesheet-reminders.ReminderEmail "Hours logged for  %period_start_date% - %period_end_date%\n"]-->
    <table cellpadding=\"3\" cellspacing=\"3\" border=\"0\">
    	<tr>
		<td style=\"font-weight:bold\">&nbsp;</td>
		<td style=\"font-weight:bold\">[lang::message::lookup "" intranet-timesheet2.Absences "Absences"]</td>
		<td style=\"font-weight:bold\">[lang::message::lookup "" intranet-timesheet-reminders.HoursLogged "Hours logged"]</td>
		<td style=\"font-weight:bold\">[lang::message::lookup "" intranet-timesheet-reminders.Target "Target"]</td>
		<td style=\"font-weight:bold\">[lang::message::lookup "" intranet-timesheet-reminders.Difference " Difference"]</td>
		<td style=\"font-weight:bold\">[lang::message::lookup "" intranet-timesheet-reminders.Links "Links"]</td>
	</tr>
        $user_record_html
	<tr>
		<td style=\"font-weight:bold\">[lang::message::lookup "" intranet-timesheet-reminders.Total "Total"]</td>
		<td>&nbsp;</td>
		<td style=\"font-weight:bold\">$total_hours_logged</td>
		<td style=\"font-weight:bold\">$total_target_hours</td>
		<td style=\"font-weight:bold\">$total_diff</td>
		<td>&nbsp;</td>
	</tr>
     </table>
    </body>
    </html>
    "
    ns_log NOTICE "intranet-timesheet-reminders-procs::im_timesheet_send_reminders_build_mailbody: LEAVING"
}

