ad_library {
    Initialization for intranet-timesheet-reminders module
    @author klaus.hofeditz@project-open.com 
}

# Check for events every hour
ad_schedule_proc -thread t [parameter::get_from_package_key -package_key intranet-timesheet-reminders -parameter EmailReminderInterval -default 3600] im_timesheet_scheduled_reminders_send
