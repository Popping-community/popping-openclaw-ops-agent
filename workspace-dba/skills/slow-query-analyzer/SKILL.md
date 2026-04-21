---
name: slow-query-analyzer
description: "SSH into EC2, fetch MySQL slow query log from Docker container or query mysqld-exporter metrics, and analyze slow queries."
metadata:
  {
    "openclaw":
      {
        "emoji": "🐢",
        "requires": { "bins": ["ssh"] },
        "install": [],
      },
  }
---

# Slow Query Analyzer Skill

Fetch and analyze MySQL slow query data from the production EC2 server.
MySQL runs inside a Docker container named `mysql`.

## Trigger Phrases

- "슬로우 쿼리 확인해줘", "느린 쿼리 분석해줘"
- "slow query", "slow log"
- "DB 성능 확인"

## Method 1: Docker Exec (Slow Query Log)

### Check Slow Query Log Status

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker exec mysql mysql -u root -p\${MYSQL_ROOT_PASSWORD} -e \"SHOW VARIABLES LIKE 'slow_query%'; SHOW VARIABLES LIKE 'long_query_time';\""
```

### Fetch Recent Slow Queries

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker exec mysql bash -c 'tail -100 /var/log/mysql/slow.log 2>/dev/null || cat /dev/null'"
```

### Check my.cnf Configuration

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "cat ~/popping-server/mysql/my.cnf 2>/dev/null || docker exec mysql cat /etc/mysql/conf.d/monitoring.cnf 2>/dev/null"
```

### Enable Slow Query Log (requires user permission)

**WARNING: Requires explicit user permission before running.**

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker exec mysql mysql -u root -p\${MYSQL_ROOT_PASSWORD} -e \"SET GLOBAL slow_query_log = 'ON'; SET GLOBAL long_query_time = 1; SET GLOBAL slow_query_log_file = '/var/log/mysql/slow.log';\""
```

## Method 2: mysqld-exporter (port 9104)

### Top Slow Queries (by total time)

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "curl -s http://localhost:9104/metrics | grep 'mysql_perf_schema_events_statements_seconds_total' | sort -t' ' -k2 -rn | head -20"
```

### Query Digest Stats

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "curl -s http://localhost:9104/metrics | grep -E 'mysql_perf_schema_events_statements_(seconds_total|rows_examined_total|digest_text)' | head -40"
```

### Full Table Scan Detection

```bash
ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222 "docker exec mysql mysql -u root -p\${MYSQL_ROOT_PASSWORD} -e \"SELECT DIGEST_TEXT, COUNT_STAR, SUM_TIMER_WAIT/1000000000000 as total_sec, SUM_ROWS_EXAMINED, SUM_NO_INDEX_USED FROM performance_schema.events_statements_summary_by_digest WHERE SUM_NO_INDEX_USED > 0 ORDER BY SUM_TIMER_WAIT DESC LIMIT 10;\""
```

## Analysis Format

```
🐢 [WARN] Slow Query Detected
- Query: SELECT ... FROM comments WHERE ...
- Execution Time: 2.3s
- Rows Examined: 150,000
- Suggestion: Add index on (post_id, created_at)
```

## Important: Cumulative vs Current

`performance_schema.events_statements_summary_by_digest` stores **cumulative** data since last MySQL restart.
High total time does NOT mean a current problem — it may be a resolved issue.

When reporting:
- Clearly state that stats are **cumulative since last restart**
- Focus on `AVG_TIMER_WAIT` (average per execution) rather than `SUM_TIMER_WAIT` (total)
- Check slow query **log** (Method 1) for **recent** slow queries — this is the real-time indicator
- If the log only shows exporter queries, report "no recent user slow queries detected"

## Analysis Checklist

1. Identify queries with `Query_time > 1s`
2. Check `Rows_examined` vs `Rows_sent` ratio (high ratio = full scan)
3. Look for missing index patterns (WHERE without index)
4. Detect N+1 query patterns (repeated similar queries)
5. Flag any table locks or deadlock waits
6. Distinguish cumulative stats from current issues
