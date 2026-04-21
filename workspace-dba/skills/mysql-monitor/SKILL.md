---
name: mysql-monitor
description: "Deep MySQL monitoring via mysqld-exporter and docker exec. Connections, InnoDB buffer pool, locks, thread cache, query analysis."
metadata:
  {
    "openclaw":
      {
        "emoji": "🔬",
        "requires": { "bins": ["ssh"] },
        "install": [],
      },
  }
---

# MySQL Deep Monitor Skill

Deep MySQL analysis via SSH to EC2.

## Trigger Phrases

- "DB 상태", "MySQL 상태", "커넥션 확인"
- "락 확인", "데드락", "InnoDB 상태"
- "버퍼풀", "인덱스 분석"

## MySQL Metrics (mysqld-exporter — port 9104)

```bash
# All key MySQL metrics at once
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "curl -s http://localhost:9104/metrics | grep -E '^mysql_global_(status|variables)_(threads_connected|max_connections|queries|slow_queries|innodb_buffer_pool_read|innodb_row_lock|threads_created|connections|table_locks_waited|aborted_connects)' | grep -v '#'"
```

## Deep Analysis Queries (via docker exec)

```bash
# InnoDB status (deadlocks, lock waits)
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker exec mysql mysql -u root -p\${MYSQL_ROOT_PASSWORD} -e 'SHOW ENGINE INNODB STATUS\G' 2>/dev/null | head -100"

# Current processlist (active queries)
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker exec mysql mysql -u root -p\${MYSQL_ROOT_PASSWORD} -e 'SHOW FULL PROCESSLIST\G' 2>/dev/null"

# Top queries by execution time (performance_schema — cumulative)
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker exec mysql mysql -u root -p\${MYSQL_ROOT_PASSWORD} -e \"SELECT DIGEST_TEXT, COUNT_STAR, ROUND(AVG_TIMER_WAIT/1000000000,2) as avg_ms, SUM_ROWS_EXAMINED, SUM_NO_INDEX_USED FROM performance_schema.events_statements_summary_by_digest ORDER BY AVG_TIMER_WAIT DESC LIMIT 10;\" 2>/dev/null"

# Table sizes
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker exec mysql mysql -u root -p\${MYSQL_ROOT_PASSWORD} -e \"SELECT TABLE_NAME, ROUND(DATA_LENGTH/1024/1024,2) as data_mb, ROUND(INDEX_LENGTH/1024/1024,2) as index_mb, TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='popping' ORDER BY DATA_LENGTH DESC LIMIT 15;\" 2>/dev/null"

# Index usage stats
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker exec mysql mysql -u root -p\${MYSQL_ROOT_PASSWORD} -e \"SELECT OBJECT_NAME, INDEX_NAME, COUNT_READ, COUNT_WRITE FROM performance_schema.table_io_waits_summary_by_index_usage WHERE OBJECT_SCHEMA='popping' ORDER BY COUNT_READ DESC LIMIT 20;\" 2>/dev/null"

# EXPLAIN a specific query (replace QUERY)
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker exec mysql mysql -u root -p\${MYSQL_ROOT_PASSWORD} -e 'EXPLAIN QUERY' 2>/dev/null"
```

## Report Format

```
🗄️ [severity] MySQL Deep Analysis

▸ Connections: {current}/{max} ({pct}%)
▸ InnoDB Buffer Pool Hit Rate: {pct}%
▸ Row Lock Waits: {value} | Avg Lock Time: {value}ms
▸ Top Slow Queries (by avg execution time):
  1. {query_digest} — avg {ms}ms, {count} executions
  2. ...
▸ Table Sizes: {table} {size}MB
▸ Unused Indexes: {list}
```
