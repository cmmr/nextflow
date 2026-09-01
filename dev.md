
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



### Globus

mkdir "$GLOBUS_DIR/nxf"
globus endpoint permission create "$GLOBUS_UUID:/nxf/" --anonymous --permissions r

globus endpoint permission list "$GLOBUS_UUID"
```
Rule ID                              | Permissions | Shared With                                                  | Path 
------------------------------------ | ----------- | ------------------------------------------------------------ | -----
b6c4edf9-a557-11f1-a946-0ee7ef9370d9 | rw          | dpsmith@bcm.edu                                              | /    
1c62badc-a58d-11f1-9ec4-0ee7ef9370d9 | r           | fallback                                                     | /nxf/
None                                 | rw          | dpsmith@bcm.edu                                              | /    
None                                 | rw          | cb94237b-af5f-41fa-b161-bd4289338137@clients.auth.globus.org | /    
None                                 | rw          | u247444@bcm.edu                                              | /
```

globus endpoint permission delete "$GLOBUS_UUID" "1c62badc-a58d-11f1-9ec4-0ee7ef9370d9"
