-- copyright (c) 2013 Project Open Business Solutions S.L.
--
-- All rights including reserved. To inquire license terms please
-- refer to https://www.project-open.com/

-- Delete time_intervals
delete from time_intervals where interval_id in (select interval_id from timespans where timespan_id in (select timespan_id from acs_events where name = 'Weekly Email Reminders' or name = 'Monthly Email Reminders')); 

-- Above delete does not remove all time intervals. For some resaond 'acs_event__insert_instances' creates two intervals. Most likely we want to delete the intervals that are not related to a timespan:
-- Until further tested this optional. 
-- delete from time_intervals where interval_id not in (select distinct interval_id from timespans); 

-- Delete timespans (Not required)
-- delete from timespans where timespan_id in (select timespan_id from acs_events where name = 'Weekly Email Reminders' or name = 'Monthly Email Reminders'); 

-- Delete cal_items
delete from cal_items where on_which_calendar in (select calendar_id from calendars where calendar_name = 'TS Email Reminders');

-- Delete recurrences 
create or replace function inline() returns integer as $BODY$
declare
        v_record                record;
begin
	FOR v_record IN
                select distinct recurrence_id from acs_events where name = 'Weekly Email Reminders' or name = 'Monthly Email Reminders' 
		LOOP
			update acs_events set recurrence_id = null where recurrence_id = v_record.recurrence_id; 
		       	delete from recurrences where recurrence_id = v_record.recurrence_id;
		END LOOP;
		return 0; 
end;$BODY$ language 'plpgsql';
select inline(); 
drop function inline();

-- Delete ACS Events 
delete from acs_events where name = 'Weekly Email Reminders' or name = 'Monthly Email Reminders';

-- Delete calendar 
delete from calendars where calendar_name = 'TS Email Reminders';

drop table im_timesheet_reminders_stats; 
drop sequence im_timesheet_reminders_stats_seq;

drop function im_timesheet_reminder_init (timestamp, varchar, timestamp, timestamp, timestamp); 






