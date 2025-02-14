# service (Ansible role)

Provision service

```yaml
---
#------------------------------------------------------------------------------
# SERVICE PROVISION
#------------------------------------------------------------------------------
# - service - #
pg_services:                                  # how to expose postgres service in cluster?
  # primary service will route {ip|name}:5433 to primary pgbouncer (5433->6432 rw)
  - name: primary           # service name {{ pg_cluster }}_primary
    src_ip: "*"
    src_port: 5433
    dst_port: pgbouncer     # 5433 route to pgbouncer
    check_url: /primary     # primary health check, success when instance is primary
    selector: "[]"          # select all instance as primary service candidate

  # replica service will route {ip|name}:5434 to replica pgbouncer (5434->6432 ro)
  - name: replica           # service name {{ pg_cluster }}_replica
    src_ip: "*"
    src_port: 5434
    dst_port: pgbouncer
    check_url: /read-only   # read-only health check. (including primary)
    selector: "[]"          # select all instance as replica service candidate
    selector_backup: "[? pg_role == `primary`]"   # primary are used as backup server in replica service

  # offline service will route {ip|name}:5435 to offline postgres (5434->5432 ro)
  - name: offline           # service name {{ pg_cluster }}_replica
    src_ip: "*"
    src_port: 5435
    dst_port: postgres
    check_url: /replica     # offline MUST be a replica
    selector: "[? pg_role == `offline` || pg_offline_query ]"         # instances with pg_role == 'offline' or instance marked with 'pg_offline_query == true'
    selector_backup: "[? pg_role == `replica` && !pg_offline_query]"  # replica are used as backup server in offline service


pg_services_extra: []
  # you can not bind default service using on-instance because *:5432 is already in use
  # when using external load balancer such as l4 vip, this can be used for virtual IP
  # # default service will route {ip|name}:5432 to primary postgres (5432->5432)
  #- name: default           # service's actual name is {{ pg_cluster }}-{{ service.name }}
  #  src_ip: "*"             # service bind ip address, * for all, vip for vip_address
  #  src_port: 5432          # bind port, mandatory
  #  dst_port: postgres      # target port: postgres|pgbouncer|port_number , pgbouncer(6432) by default
  #  check_method: http      # health check method: only http is available for now
  #  check_port: patroni     # health check port:  patroni|pg_exporter|port_number , patroni by default
  #  check_url: /primary     # health check url path, / as default
  #  check_code: 200         # health check http code, 200 as default
  #  selector: "[]"          # instance selector
  #  haproxy:                # haproxy specific fields
  #    maxconn: 3000         # default front-end connection
  #    balance: roundrobin   # load balance algorithm (roundrobin by default)
  #    default_server_options: 'inter 3s fastinter 1s downinter 5s rise 3 fall 3 on-marked-down shutdown-sessions slowstart 30s maxconn 3000 maxqueue 128 weight 100'

# - haproxy - #
haproxy_enabled: true                         # enable haproxy among every cluster members
haproxy_reload: true                          # reload configuration after config?
haproxy_policy: roundrobin                    # roundrobin, leastconn
haproxy_admin_auth_enabled: true              # enable authentication for haproxy admin?
haproxy_admin_username: admin                 # default haproxy admin username
haproxy_admin_password: admin                 # default haproxy admin password
haproxy_exporter_port: 9101                   # default admin/exporter port
haproxy_client_timeout: 3h                    # client side connection timeout
haproxy_server_timeout: 3h                    # server side connection timeout

# - vip - #
vip_mode: none                                # none | l2 | l4
vip_reload: true                              # whether reload & restart proxy after config?
vip_address: 127.0.0.1                        # virtual ip address ip (l2 or l4)
vip_cidrmask: 24                              # virtual ip address cidr mask (l2 only)
vip_interface: eth0                           # virtual ip network interface (l2 only)

# - reference - #
pg_namespace: /pg                             # top level key namespace in dcs (l2)
pg_weight: 100
pg_port: 5432
pgbouncer_port: 6432
patroni_port: 8008
pg_exporter_port: 9630
service_registry: consul                      # none | consul | etcd | both
exporter_metrics_path: /metrics               # url path to expose metrics
...
```