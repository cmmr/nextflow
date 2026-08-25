
### Make every *.sh file executable

In a `git bash` shell:
```bash
git ls-files "*.sh" | xargs git update-index --chmod=+x
git update-index --chmod=+x run
```


### For complaints during `git pull`:

```bash
git fetch origin
git reset --hard @{u}
```


### Daemon control

source /data/prod/nextflow/.env
aws sqs purge-queue --queue-url "$AWS_SQS_QUEUE_URL" --region "$AWS_REGION"

systemctl --user start wrike-sqs-listener

systemctl --user status wrike-sqs-listener
journalctl --user -u wrike-sqs-listener --since today