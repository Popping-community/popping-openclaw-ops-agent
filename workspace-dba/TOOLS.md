# TOOLS.md - PoppingDBA Environment

## Architecture

```
EC2 (`EC2_HOST`)
├── mysql (Docker container, port 3306)
└── mysqld-exporter (`MYSQL_EXPORTER_PORT`)
```

## SSH

- `ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p "$EC2_SSH_PORT" "${EC2_SSH_USER}@${EC2_HOST}"`
- Target values are required Railway Variables and are not stored in this public repository.
- MySQL: `docker exec mysql mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "QUERY"`

## Metrics

- mysqld-exporter: `curl -s "http://localhost:${MYSQL_EXPORTER_PORT}/metrics"`
- Slow query log: `docker exec mysql bash -c 'tail -100 /var/log/mysql/slow.log'`
