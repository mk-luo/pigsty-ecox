----------------------------------------------------------------------
-- File      :   pg-init-template.sql
-- Ctime     :   2018-10-30
-- Mtime     :   2021-02-27
-- Desc      :   init postgres cluster template
-- Path      :   /pg/tmp/pg-init-template.sql
-- Author    :   Vonng(fengruohang@outlook.com)
-- Copyright (C) 2018-2021 Ruohang Feng
----------------------------------------------------------------------


--==================================================================--
--                           Executions                             --
--==================================================================--
-- psql template1 -AXtwqf /pg/tmp/pg-init-template.sql
-- this sql scripts is responsible for post-init procedure
-- it will
--    * create system users such as replicator, monitor user, admin user
--    * create system default roles
--    * create schema, extensions in template1 & postgres
--    * create monitor views in template1 & postgres


--==================================================================--
--                          Default Privileges                      --
--==================================================================--
{% for priv in pg_default_privileges %}
ALTER DEFAULT PRIVILEGES FOR ROLE {{ pg_dbsu }} {{ priv }};
{% endfor %}

{% for priv in pg_default_privileges %}
ALTER DEFAULT PRIVILEGES FOR ROLE {{ pg_admin_username }} {{ priv }};
{% endfor %}

-- for additional business admin, they can SET ROLE to dbrole_admin
{% for priv in pg_default_privileges %}
ALTER DEFAULT PRIVILEGES FOR ROLE "dbrole_admin" {{ priv }};
{% endfor %}

--==================================================================--
--                              Schemas                             --
--==================================================================--
{% for schema_name in pg_default_schemas %}
CREATE SCHEMA IF NOT EXISTS "{{ schema_name }}";
{% endfor %}

-- revoke public creation
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

--==================================================================--
--                             Extensions                           --
--==================================================================--
{% for extension in pg_default_extensions %}
CREATE EXTENSION IF NOT EXISTS "{{ extension.name }}"{% if 'schema' in extension %} WITH SCHEMA "{{ extension.schema }}"{% endif %};
{% endfor %}



--==================================================================--
--                            Monitor Views                         --
--==================================================================--

----------------------------------------------------------------------
-- cleanse
----------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS monitor;
GRANT USAGE ON SCHEMA monitor TO "{{ pg_monitor_username }}";
--GRANT USAGE ON SCHEMA monitor TO "{{ pg_admin_username }}";
--GRANT USAGE ON SCHEMA monitor TO "{{ pg_replication_username }}";

DROP VIEW IF EXISTS monitor.pg_table_bloat_human;
DROP VIEW IF EXISTS monitor.pg_index_bloat_human;
DROP VIEW IF EXISTS monitor.pg_table_bloat;
DROP VIEW IF EXISTS monitor.pg_index_bloat;
DROP VIEW IF EXISTS monitor.pg_session;
DROP VIEW IF EXISTS monitor.pg_kill;
DROP VIEW IF EXISTS monitor.pg_cancel;
DROP VIEW IF EXISTS monitor.pg_seq_scan;


----------------------------------------------------------------------
-- Table bloat estimate
----------------------------------------------------------------------
CREATE OR REPLACE VIEW monitor.pg_table_bloat AS
    SELECT CURRENT_CATALOG AS datname, nspname, relname , bs * tblpages AS size,
           CASE WHEN tblpages - est_tblpages_ff > 0 THEN (tblpages - est_tblpages_ff)/tblpages::FLOAT ELSE 0 END AS ratio
    FROM (
             SELECT ceil( reltuples / ( (bs-page_hdr)*fillfactor/(tpl_size*100) ) ) + ceil( toasttuples / 4 ) AS est_tblpages_ff,
                    tblpages, fillfactor, bs, tblid, nspname, relname, is_na
             FROM (
                      SELECT
                          ( 4 + tpl_hdr_size + tpl_data_size + (2 * ma)
                              - CASE WHEN tpl_hdr_size % ma = 0 THEN ma ELSE tpl_hdr_size % ma END
                              - CASE WHEN ceil(tpl_data_size)::INT % ma = 0 THEN ma ELSE ceil(tpl_data_size)::INT % ma END
                              ) AS tpl_size, (heappages + toastpages) AS tblpages, heappages,
                          toastpages, reltuples, toasttuples, bs, page_hdr, tblid, nspname, relname, fillfactor, is_na
                      FROM (
                               SELECT
                                   tbl.oid AS tblid, ns.nspname , tbl.relname, tbl.reltuples,
                                   tbl.relpages AS heappages, coalesce(toast.relpages, 0) AS toastpages,
                                   coalesce(toast.reltuples, 0) AS toasttuples,
                                   coalesce(substring(array_to_string(tbl.reloptions, ' ') FROM 'fillfactor=([0-9]+)')::smallint, 100) AS fillfactor,
                                   current_setting('block_size')::numeric AS bs,
                                   CASE WHEN version()~'mingw32' OR version()~'64-bit|x86_64|ppc64|ia64|amd64' THEN 8 ELSE 4 END AS ma,
                                   24 AS page_hdr,
                                   23 + CASE WHEN MAX(coalesce(s.null_frac,0)) > 0 THEN ( 7 + count(s.attname) ) / 8 ELSE 0::int END
                                       + CASE WHEN bool_or(att.attname = 'oid' and att.attnum < 0) THEN 4 ELSE 0 END AS tpl_hdr_size,
                                   sum( (1-coalesce(s.null_frac, 0)) * coalesce(s.avg_width, 0) ) AS tpl_data_size,
                                   bool_or(att.atttypid = 'pg_catalog.name'::regtype)
                                       OR sum(CASE WHEN att.attnum > 0 THEN 1 ELSE 0 END) <> count(s.attname) AS is_na
                               FROM pg_attribute AS att
                                        JOIN pg_class AS tbl ON att.attrelid = tbl.oid
                                        JOIN pg_namespace AS ns ON ns.oid = tbl.relnamespace
                                        LEFT JOIN pg_stats AS s ON s.schemaname=ns.nspname AND s.tablename = tbl.relname AND s.inherited=false AND s.attname=att.attname
                                        LEFT JOIN pg_class AS toast ON tbl.reltoastrelid = toast.oid
                               WHERE NOT att.attisdropped AND tbl.relkind = 'r' AND nspname NOT IN ('pg_catalog','information_schema')
                               GROUP BY 1,2,3,4,5,6,7,8,9,10
                           ) AS s
                  ) AS s2
         ) AS s3
    WHERE NOT is_na;
COMMENT ON VIEW monitor.pg_table_bloat IS 'postgres table bloat estimate';

----------------------------------------------------------------------
-- Index bloat estimate
----------------------------------------------------------------------
CREATE OR REPLACE VIEW monitor.pg_index_bloat AS
    SELECT CURRENT_CATALOG AS datname, nspname, idxname AS relname, relpages::BIGINT * bs AS size,
           COALESCE((relpages - ( reltuples * (6 + ma - (CASE WHEN index_tuple_hdr % ma = 0 THEN ma ELSE index_tuple_hdr % ma END)
                                                   + nulldatawidth + ma - (CASE WHEN nulldatawidth % ma = 0 THEN ma ELSE nulldatawidth % ma END))
                                      / (bs - pagehdr)::FLOAT  + 1 )), 0) / relpages::FLOAT AS ratio
    FROM (
             SELECT nspname,
                    idxname,
                    reltuples,
                    relpages,
                    current_setting('block_size')::INTEGER                                                               AS bs,
                    (CASE WHEN version() ~ 'mingw32' OR version() ~ '64-bit|x86_64|ppc64|ia64|amd64' THEN 8 ELSE 4 END)  AS ma,
                    24                                                                                                   AS pagehdr,
                    (CASE WHEN max(COALESCE(pg_stats.null_frac, 0)) = 0 THEN 2 ELSE 6 END)                               AS index_tuple_hdr,
                    sum((1.0 - COALESCE(pg_stats.null_frac, 0.0)) *
                        COALESCE(pg_stats.avg_width, 1024))::INTEGER                                                     AS nulldatawidth
             FROM pg_attribute
                      JOIN (
                 SELECT pg_namespace.nspname,
                        ic.relname                                                   AS idxname,
                        ic.reltuples,
                        ic.relpages,
                        pg_index.indrelid,
                        pg_index.indexrelid,
                        tc.relname                                                   AS tablename,
                        regexp_split_to_table(pg_index.indkey::TEXT, ' ') :: INTEGER AS attnum,
                        pg_index.indexrelid                                          AS index_oid
                 FROM pg_index
                          JOIN pg_class ic ON pg_index.indexrelid = ic.oid
                          JOIN pg_class tc ON pg_index.indrelid = tc.oid
                          JOIN pg_namespace ON pg_namespace.oid = ic.relnamespace
                          JOIN pg_am ON ic.relam = pg_am.oid
                 WHERE pg_am.amname = 'btree' AND ic.relpages > 0 AND nspname NOT IN ('pg_catalog', 'information_schema')
             ) ind_atts ON pg_attribute.attrelid = ind_atts.indexrelid AND pg_attribute.attnum = ind_atts.attnum
                      JOIN pg_stats ON pg_stats.schemaname = ind_atts.nspname
                 AND ((pg_stats.tablename = ind_atts.tablename AND pg_stats.attname = pg_get_indexdef(pg_attribute.attrelid, pg_attribute.attnum, TRUE))
                     OR (pg_stats.tablename = ind_atts.idxname AND pg_stats.attname = pg_attribute.attname))
             WHERE pg_attribute.attnum > 0
             GROUP BY 1, 2, 3, 4, 5, 6
         ) est
    LIMIT 512;
COMMENT ON VIEW monitor.pg_index_bloat IS 'postgres index bloat estimate (btree-only)';

----------------------------------------------------------------------
-- table bloat pretty
----------------------------------------------------------------------
CREATE OR REPLACE VIEW monitor.pg_table_bloat_human AS
SELECT nspname || '.' || relname AS name,
       pg_size_pretty(size)      AS size,
       pg_size_pretty((size * ratio)::BIGINT) AS wasted,
       round(100 * ratio::NUMERIC, 2)  as ratio
FROM monitor.pg_table_bloat ORDER BY wasted DESC NULLS LAST;
COMMENT ON VIEW monitor.pg_table_bloat_human IS 'postgres table bloat pretty';

----------------------------------------------------------------------
-- index bloat pretty
----------------------------------------------------------------------
CREATE OR REPLACE VIEW monitor.pg_index_bloat_human AS
SELECT nspname || '.' || relname              AS name,
       pg_size_pretty(size)                   AS size,
       pg_size_pretty((size * ratio)::BIGINT) AS wasted,
       round(100 * ratio::NUMERIC, 2)         as ratio
FROM monitor.pg_index_bloat;
COMMENT ON VIEW monitor.pg_index_bloat_human IS 'postgres index bloat pretty';


----------------------------------------------------------------------
-- pg session
----------------------------------------------------------------------
CREATE OR REPLACE VIEW monitor.pg_session AS
SELECT coalesce(datname, 'all') AS datname,
       numbackends,
       active,
       idle,
       ixact,
       max_duration,
       max_tx_duration,
       max_conn_duration
FROM (
         SELECT datname,
                count(*)                                         AS numbackends,
                count(*) FILTER ( WHERE state = 'active' )       AS active,
                count(*) FILTER ( WHERE state = 'idle' )         AS idle,
                count(*) FILTER ( WHERE state = 'idle in transaction'
                    OR state = 'idle in transaction (aborted)' ) AS ixact,
                max(extract(epoch from now() - state_change))
                FILTER ( WHERE state = 'active' )                AS max_duration,
                max(extract(epoch from now() - xact_start))      AS max_tx_duration,
                max(extract(epoch from now() - backend_start))   AS max_conn_duration
         FROM pg_stat_activity
         WHERE backend_type = 'client backend'
           AND pid <> pg_backend_pid()
         GROUP BY ROLLUP (1)
         ORDER BY 1 NULLS FIRST
     ) t;
COMMENT ON VIEW monitor.pg_session IS 'postgres session stats';


----------------------------------------------------------------------
-- pg kill
----------------------------------------------------------------------
CREATE OR REPLACE VIEW monitor.pg_kill AS
SELECT pid,
       pg_terminate_backend(pid)                 AS killed,
       datname                                   AS dat,
       usename                                   AS usr,
       application_name                          AS app,
       client_addr                               AS addr,
       state,
       extract(epoch from now() - state_change)  AS query_time,
       extract(epoch from now() - xact_start)    AS xact_time,
       extract(epoch from now() - backend_start) AS conn_time,
       substring(query, 1, 40)                   AS query
FROM pg_stat_activity
WHERE backend_type = 'client backend'
  AND pid <> pg_backend_pid();
COMMENT ON VIEW monitor.pg_kill IS 'kill all backend session';


----------------------------------------------------------------------
-- quick cancel view
----------------------------------------------------------------------
DROP VIEW IF EXISTS monitor.pg_cancel;
CREATE OR REPLACE VIEW monitor.pg_cancel AS
SELECT pid,
       pg_cancel_backend(pid)                    AS cancel,
       datname                                   AS dat,
       usename                                   AS usr,
       application_name                          AS app,
       client_addr                               AS addr,
       state,
       extract(epoch from now() - state_change)  AS query_time,
       extract(epoch from now() - xact_start)    AS xact_time,
       extract(epoch from now() - backend_start) AS conn_time,
       substring(query, 1, 40)
FROM pg_stat_activity
WHERE state = 'active'
  AND backend_type = 'client backend'
  and pid <> pg_backend_pid();
COMMENT ON VIEW monitor.pg_cancel IS 'cancel backend queries';


----------------------------------------------------------------------
-- seq scan
----------------------------------------------------------------------
DROP VIEW IF EXISTS monitor.pg_seq_scan;
CREATE OR REPLACE VIEW monitor.pg_seq_scan AS
SELECT schemaname                             AS nspname,
       relname,
       seq_scan,
       seq_tup_read,
       seq_tup_read / seq_scan                AS seq_tup_avg,
       idx_scan,
       n_live_tup + n_dead_tup                AS tuples,
       n_live_tup / (n_live_tup + n_dead_tup) AS dead_ratio
FROM pg_stat_user_tables
WHERE seq_scan > 0
  and (n_live_tup + n_dead_tup) > 0
ORDER BY seq_tup_read DESC
LIMIT 50;
COMMENT ON VIEW monitor.pg_seq_scan IS 'table that have seq scan';


{% if pg_version >= 13 %}
----------------------------------------------------------------------
-- pg_shmem auxiliary function
-- PG 13 ONLY!
----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION monitor.pg_shmem() RETURNS SETOF
    pg_shmem_allocations AS $$ SELECT * FROM pg_shmem_allocations;$$ LANGUAGE SQL SECURITY DEFINER;
COMMENT ON FUNCTION monitor.pg_shmem() IS 'security wrapper for pg_shmem';
{% endif %}


--==================================================================--
--                          Customize Logic                         --
--==================================================================--
-- This script will be execute on primary instance among a newly created
-- postgres cluster. it will be executed as dbsu on template1 database
-- put your own customize logic here
-- make sure they are idempotent