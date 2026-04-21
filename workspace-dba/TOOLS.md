# TOOLS.md - PoppingDBA Environment

## Architecture

```
EC2 (52.79.56.222)
├── mysql (Docker container, port 3306)
└── mysqld-exporter (port 9104)
```

## SSH

- `ssh -i /root/.ssh/ec2-key.pem -o StrictHostKeyChecking=no -p 2222 ec2-user@52.79.56.222`
- MySQL: `docker exec mysql mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "QUERY"`

## Metrics

- mysqld-exporter: `curl -s http://localhost:9104/metrics`
- Slow query log: `docker exec mysql bash -c 'tail -100 /var/log/mysql/slow.log'`
