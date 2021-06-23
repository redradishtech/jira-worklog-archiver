-- Worklog Archiver
--
-- Jira (and specifically, Tempo) chokes when issues have too many worklogs. This script 'archives' old worklogs on heavily used tickets to a linked 'archive' ticket.
--
-- Specifically, the script:
-- - Finds issues with a Worklog Archive link, whose outgoing link type is typically named 'old worklogs archived at'.
--   (Note that users need to manually create the archive ticket and link it.)
-- - checks if the ticket has over 10,000 worklogs
-- - if so, worklogs older than 3 months are moved to the archive ticket
--
-- In implementing a 'worklog move' functionality, there are two choices:
-- 1) 'clone' the worklog to a new issue and delete the old one (which is what Tempo's "move worklog" does)
-- 2) 'edit' the worklog by giving it a new parent issue (i.e. change worklog.issueid).
--
-- This script goes the second route, keeping the worklog database records unchanged except for rewriting worklog.issueid.
-- This choice avoids cascading effects on plugins that refer to worklogs by ID. E.g. Tempo's AO_013613_WA_VALUE table
-- (worklog attributes) references worklogs by ID. By not changing worklog IDs we avoid having to update AO_013613_WA_VALUE.
--
-- Note that each worklog also has a change history, comprising a changegroup and 3 changeitem records. This script does not
-- move the change history to the archive issue. It wq
--
--
--
--
-- ould be easy to do so, but leaving the change history intact on the original
-- issue seems least intrusive and more honest, and has no performance impact.

--     jeff@redradishtech.com, 17/Jun/21

SET client_min_messages TO debug1;

create or replace function archive_old_worklogs(oldissueid numeric, newissueid numeric) returns void as
$$
DECLARE
    wltotal     integer := (select count(*)
                            from worklog
                            where issueid = oldissueid);
    wlcopycount integer;
    wlcopysum   bigint;
    oldissue    varchar := (select project.pkey || '-' || jiraissue.issuenum
                            from project
                                     JOIN jiraissue ON project.id = jiraissue.project
                            where jiraissue.id = oldissueid);
    newissue    varchar := (select project.pkey || '-' || jiraissue.issuenum
                            from project
                                     JOIN jiraissue ON project.id = jiraissue.project
                            where jiraissue.id = newissueid);

BEGIN
    if (wltotal > 10000) then
        raise notice '% has % worklogs (over the 10,000 limit). Checking if some can be moved to archive issue %', oldissue, wltotal, newissue;
        assert exists(select * from jiraissue where id = oldissueid), format('issue %s does not exist', oldissueid);
        assert exists(select * from jiraissue where id = newissueid), format('issue %s does not exist', newissueid);
-- For each of «oldissueid»'s worklogs that don't have a «newissueid» equivalent yet..

        create temp table myworklogs AS
        select *
        from worklog
        where issueid = oldissueid
          and worklog.created < now() - '1 month'::interval;
        select count(*) into wlcopycount from myworklogs;
        raise notice 'There are % worklogs that need copying from % to %', wlcopycount, oldissue, newissue;
        update worklog set issueid=newissueid from myworklogs where worklog.id = myworklogs.id;
        select coalesce(sum(timeworked), 0) into wlcopysum from myworklogs;
        update jiraissue set timespent=timespent - wlcopysum where id = oldissueid;
        update jiraissue set timespent=timespent + wlcopysum where id = newissueid;
        raise notice 'Copied % worklogs from % to %, adjusting issue worklog times by % seconds', wlcopycount, oldissue, newissue, wlcopysum;
        drop table myworklogs;
    else
        raise notice '% has only % worklogs', oldissue, wltotal;
    end if;
END
$$ LANGUAGE plpgsql;

do
$$
    BEGIN
        perform archive_old_worklogs(source, destination)
        from issuelink
        where linktype = (select id from issuelinktype where linkname = 'Worklog Archive');
    END
$$
;
