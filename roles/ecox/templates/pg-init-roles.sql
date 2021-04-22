----------------------------------------------------------------------
-- File      :   pg-init-roles.sql
-- Path      :   /pg/tmp/pg-init-roles
-- Time      :   {{ '%Y-%m-%d %H:%M' | strftime }}
-- Note      :   managed by ansible, DO NOT CHANGE
-- Desc      :   creation sql script for default roles
----------------------------------------------------------------------

{% for user in pg_default_roles %}

--###################################################################--
--                         {{ user.name }}                           --
--###################################################################--
-- run as dbsu (postgres by default)
-- createuser -w -p {{ pg_port }} {% if 'login' in user and not user.login %}--no-login{% endif %}
{% if 'superuser' in user and user.superuser %} --superuser{% endif %}
{% if 'createdb' in user and user.createdb %} --createdb{% endif %}
{% if 'createrole' in user and user.createrole %} --createrole{% endif %}
{% if 'inherit' in user and not user.inherit %} --no-inherit{% endif %}
{% if 'replication' in user and user.replication %} --replication{% endif %}
'{{ user.name }}';
-- psql -p {{ pg_port }} -AXtwqf /pg/tmp/pg-user-{{ user.name }}.sql

--==================================================================--
--                           CREATE USER                            --
--==================================================================--
CREATE USER "{{ user.name }}" {% if 'login' in user and not user.login %} NOLOGIN{% endif %}
{% if 'superuser' in user and user.superuser %} SUPERUSER{% endif %}
{% if 'createdb' in user and user.createdb %} CREATEDB{% endif %}
{% if 'createrole' in user and user.createrole %} CREATEROLE{% endif %}
{% if 'inherit' in user and not user.inherit %} NOINHERIT{% endif %}
{% if 'replication' in user and user.replication %} REPLICATION{% endif %}
{% if 'bypassrls' in user and user.bypassrls %} BYPASSRLS{% endif %}
;

--==================================================================--
--                           ALTER USER                             --
--==================================================================--
-- options
ALTER USER "{{ user.name }}" {% if 'login' in user and not user.login %} NOLOGIN{% endif %}
{% if 'superuser' in user and user.superuser %} SUPERUSER{% endif %}
{% if 'createdb' in user and user.createdb %} CREATEDB{% endif %}
{% if 'createrole' in user and user.createrole %} CREATEROLE{% endif %}
{% if 'inherit' in user and not user.inherit %} NOINHERIT{% endif %}
{% if 'replication' in user and user.replication %} REPLICATION{% endif %}
{% if 'bypassrls' in user and user.bypassrls %} BYPASSRLS{% endif %}
;

-- password
{% if 'password' in user %}
ALTER USER "{{ user.name }}" PASSWORD '{{ user.password }}';
{% endif %}

-- expire
{% if 'expire_in' in user %}
-- expire at {{ '%Y-%m-%d' | strftime(('%s' | strftime() | int  + user.expire_in * 86400)|int)  }} in {{ user.expire_in }} days since {{ '%Y-%m-%d' | strftime }}
ALTER USER "{{ user.name }}" VALID UNTIL '{{ '%Y-%m-%d' | strftime(('%s' | strftime() | int  + user.expire_in * 86400)|int)  }}';
{% elif 'expire_at' in user %}
-- expire at {{ user.expire_at }}
ALTER USER "{{ user.name }}" VALID UNTIL '{{ user.expire_at }}';
{% endif %}

-- conn limit
{% if 'connlimit' in user %}
{% if user.connlimit == -1 %} -- remove conn limit
-- {% endif %}
ALTER USER "{{ user.name }}" CONNECTION LIMIT {{ user.connlimit }};
{% endif %}

-- parameters
{% if 'parameters' in user %}
{% for key, value in user.parameters.items() %}
ALTER USER "{{ user.name }}" SET {{ key }} = {{ value }};
{% endfor %}{% endif %}

-- comment
{% if 'comment' in user %}
COMMENT ON ROLE "{{ user.name }}" IS '{{ user.comment }}';
{% else %}
COMMENT ON ROLE "{{ user.name }}" IS 'business user {{ user.name }}';
{% endif %}


--==================================================================--
--                           GRANT ROLE                             --
--==================================================================--
{% if 'roles' in user %}
{% for role in user.roles %}
GRANT "{{ role }}" TO "{{ user.name }}";
{% endfor %}
{% endif %}


--==================================================================--
--                          PGBOUNCER USER                          --
--==================================================================--
-- user will not be added to pgbouncer user list by default,
-- unless pgbouncer is explicitly set to 'true', which means production user

{% if 'pgbouncer' in user and user.pgbouncer|bool == true %}
-- User '{{ user.name }}' will be added to /etc/pgbouncer/userlist.txt via
-- /pg/bin/pgbouncer-create-user '{{ user.name }}' '{% if 'password' in user %}{{ user.password }}{% else %}auto{% endif %}'
{% else %}
-- User '{{ user.name }}' will NOT be added to /etc/pgbouncer/userlist.txt
{% endif %}

--==================================================================--



{% endfor %}


CREATE USER user_for_rewind WITH NOCREATEROLE SUPERUSER PASSWORD 'PostgreSQL@ww-it.cn' CONNECTION LIMIT 8

--==================================================================--
--                       PASSWORD OVERWRITE                         --
--==================================================================--
--ALTER ROLE "{{ pg_replication_username }}" PASSWORD '{{ pg_replication_password }}';
ALTER ROLE "{{ pg_monitor_username }}" PASSWORD '{{ pg_monitor_password }}';
--ALTER ROLE "{{ pg_admin_username }}" PASSWORD '{{ pg_admin_password }}';
--==================================================================--

