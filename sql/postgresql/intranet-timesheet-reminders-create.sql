-- copyright (c) 2013 Project Open Business Solutions S.L.
--
-- All rights including reserved. To inquire license terms please
-- refer to http://www.project-open.com/

-------------------------------------------------------------
-- Reminder Module 
-- Send scheduled reminders.  
     
-- create calendar for system activities, owner is group SysAdmin

CREATE OR REPLACE FUNCTION inline_0 () RETURNS VOID AS $BODY$
declare
        v_count                 integer;
	calendar_id		integer;
begin

        select count(*) into v_count from calendars where calendar_name = 'TS Email Reminders' and owner_id = 459;
 
        IF      0 = v_count
        THEN
                SELECT calendar__new(
                null,           -- calendar_id
                'TS Email Reminders',        -- calendar_name
                'calendar',     -- object_type
                459,            -- owner_id
                'f',            -- private_p
                (select package_id from apm_packages where package_key = 'intranet-timesheet-reminder'), -- package_id
                (select package_id from apm_packages where package_key = 'intranet-timesheet-reminder'), -- context_id
                now(),          -- creation_date
                null,           -- creation_user
                '0.0.0.0'       -- creation_ip
                ) into calendar_id;
        END IF;
end;$BODY$ LANGUAGE 'plpgsql';
select inline_0 ();
DROP FUNCTION inline_0 ();


CREATE OR REPLACE FUNCTION inline_0 () RETURNS VOID AS $BODY$
declare
        v_count                 integer;
        calendar_id             integer;
begin

	select count(*) into v_count from pg_tables where tablename = 'im_timesheet_reminders_stats';

        IF      0 = v_count
        THEN
		-- Track reminders  
		create sequence im_timesheet_reminders_stats_seq;
		create table im_timesheet_reminders_stats (
		        id   		integer
                			primary key,
			event_id	integer
					constraint im_timesheet_reminders_stats_event_fk references acs_events,
			triggered	timestamp,
			notes		text
		);
		ALTER TABLE im_timesheet_reminders_stats ALTER COLUMN id SET DEFAULT NEXTVAL('im_timesheet_reminders_stats_seq');
        END IF;
end;$BODY$ LANGUAGE 'plpgsql';
select inline_0 ();
DROP FUNCTION inline_0 ();

-- Create calender_item & reoccurance  
-- Example: 
-- 	"Weekly First Timespan": Next Saturday 12:00 
--	"weekly_days_of_week": 6 (Saturday) 
--	"Weekly Until": "Weekly First Timespan" + 20 years 
--	"Monthly First Timespan": 1st of following month 
--	"Monthly Until": "Monthly First Timespan" + 20 years
-- select im_timesheet_reminder_init('2013-12-21 12:00','6','2033-12-21', '2014-01-01 12:00', '2034-01-01')

CREATE OR REPLACE FUNCTION im_timesheet_reminder_init (timestamp, varchar, timestamp, timestamp, timestamp) RETURNS VOID AS $BODY$
 
declare

	weekly_first_timespan		alias for $1;  
	weekly_days_of_week		alias for $2;
	weekly_until			alias for $3;
	monthly_first_timespan		alias for $4;
	monthly_until			alias for $5;
        v_count				integer;
        v_calendar_id			integer;
        v_recurrance_weekly_id		integer;
        v_recurrance_monthly_id		integer;
	v_timespan_weekly_id		integer;
	v_timespan_monthly_id		integer;
        v_calendar_item_weekly_id	integer;
        v_calendar_item_monthly_id	integer;
	v_event_weekly_id		integer;
	v_event_monthly_id		integer;
begin

        -- get calendar_id 
        select calendar_id into v_calendar_id from calendars where calendar_name = 'TS Email Reminders' and owner_id=459; 
        
        -- create weekly recurrance
        select recurrence__new(
                'week',			      -- weekly 
                1,                     	      -- every_n,
                weekly_days_of_week,	      -- days_of_week (Saturday) 
                weekly_until,		      --recur_until,
                null) into v_recurrance_weekly_id; 

        -- create monthly recurrance
        select recurrence__new(
                'month_by_date',	      -- monthly 
                1,                     	      -- every_n,
                '',			      -- days_of_week 
                monthly_until, 		      -- recur_until,
                null) into v_recurrance_monthly_id; 

	-- Create timespan for weekly recurrance 
	select timespan__new (weekly_first_timespan, weekly_first_timespan) into v_timespan_weekly_id;

	-- Create timespan for monthly recurrance 
	select timespan__new (monthly_first_timespan, monthly_first_timespan) into v_timespan_monthly_id;

        -- create calender_item for weekly reminders 
        select cal_item__new(
	       null,				
	       v_calendar_id,			-- Cal id 
	       'Weekly Email Reminders',	-- Name 
	       '',     	     			 
	       'f',
	       '',
	       v_timespan_weekly_id,		-- timespan_id
	       null,				-- activity_id
	       v_recurrance_weekly_id,		-- recurrence
	       'cal_item',
	       null,
	       now(),
	       null,
	       '0.0.0.0') into v_calendar_item_weekly_id; 

        -- create calender_item for monthly reminders
        select cal_item__new(
               null,
               v_calendar_id,			-- Cal id
               'Monthly Email Reminders',       -- Name
               '',
               'f',
               '',
               v_timespan_monthly_id,		-- timespan_id
               null,                    	-- activity_id
               v_recurrance_monthly_id,		-- recurrence
               'cal_item',
               null,
               now(),
               null,
               '0.0.0.0') into v_calendar_item_monthly_id;

	-- create weekly event 
	-- select acs_event__new(
	--	  null,				      -- new__event_id        
	--          'Weekly Email Reminder',	      -- new__name            
     	--	  '',      	 		      -- new__description     
     	--	  'f',                                -- new__html_p          
     	--	  '',                                 -- new__status_summary  
     	--	  null,                               -- new__timespan_id
     	--	  null,                               -- new__activity_id     
     	--	  v_recurrance_weekly_id,             -- new__recurrence_id   
     	--	  'acs_event',                        -- new__object_type      
     	--	  now(),                              -- new__creation_date   
     	--	  null,                               -- new__creation_user   
    	--	  '0.0.0.0',                          -- new__creation_ip     
     	--	  null,                               -- new__context_id      
    	--	  null                                -- new__package_id                          
        -- ) into v_event_weekly_id;   

	-- create monthly event 
	-- select acs_event__new(
	--	  null,					-- new__event_id        
	--        'Monthly Email Reminder',     	-- new__name            
     	--	  '',      	 			-- new__description     
     	--	  'f',                                	-- new__html_p          
     	--	  '',                                 	-- new__status_summary  
     	--	  null,                               	-- new__timespan_id
     	--	  null,                               	-- new__activity_id     
     	--	  v_recurrance_monthly_id,              -- new__recurrence_id   
     	--	  'acs_event',                        	-- new__object_type      
     	--	  now(),                              	-- new__creation_date   
     	--	  null,                               	-- new__creation_user   
    	--	  '0.0.0.0',                          	-- new__creation_ip     
     	--	  null,                               	-- new__context_id      
    	--	  null                                	-- new__package_id                          
        -- ) into v_event_monthly_id;   

        -- insert weekly instances 
        select acs_event__insert_instances(v_calendar_item_weekly_id, weekly_until::date) into v_event_weekly_id;

        -- insert monthly instances 
        select acs_event__insert_instances(v_calendar_item_monthly_id, monthly_until::date) into v_event_monthly_id;

	-- Only necessary when cal items need to be shown in calendar 
	-- 
	-- create all cal items for weekly reminders 
        -- insert into cal_items (cal_item_id, on_which_calendar, item_type_id)
        -- select
        --        event_id,
        --        (select on_which_calendar as calendar_id from cal_items where cal_item_id = v_calendar_item_weekly_id),
        --        (select item_type_id as item_type from cal_items where cal_item_id = v_calendar_item_weekly_id)
        -- from
        --        acs_events
        -- where
        --        recurrence_id= v_recurrance_weekly_id
        --        and event_id <> v_calendar_item_weekly_id;

        -- create all cal items for monthly reminders
        -- insert into cal_items (cal_item_id, on_which_calendar, item_type_id)
        -- select
        --         event_id,
        --        (select on_which_calendar as calendar_id from cal_items where cal_item_id = v_calendar_item_monthly_id),
        --        (select item_type_id as item_type from cal_items where cal_item_id = v_calendar_item_monthly_id)
        -- from
        --         acs_events
        -- where
        --        recurrence_id= v_recurrance_monthly_id
        --        and event_id <> v_calendar_item_monthly_id;

end;$BODY$ LANGUAGE 'plpgsql';

