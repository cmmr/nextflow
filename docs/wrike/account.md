# The Wrike side

A bot account exists under `dpsmith@bcm.edu` ("Cluster Bot", `KUAYXHNY`),
distinct from Daniel's normal `Daniel.Smith@bcm.edu` account.

**The bot is a regular user**, so it holds a license seat and everything in this
system runs as it: commenting, attaching files, writing custom fields, setting
task status, and creating tasks — which is what lets [`run`](../../run) file a request
on a caller's behalf rather than making every user bring a token of their own.

It was a Collaborator until August 2026. That costs no seat, but Collaborators
may not create tasks (`403 not_allowed`, a license restriction rather than a
permission grantable on the folder) *or edit custom fields* — and a rejected
custom field write comes back `200` with the change quietly dropped, which is why
`update_wrike_custom_field` reads the reply back and warns when Wrike did not
apply what it was asked for.

To check which account a token belongs to:

```bash
curl -sS -H "Authorization: bearer $WRIKE_API_TOKEN" "https://www.wrike.com/api/v4/contacts?me=true" | jq '.data[0].profiles'
```

A "Nextflow Pipelines" space holds the
"Dashboards" folder that tracks every submitted job, and the "Bioinformatics
Pipeline" request form that creates tasks in it — see
[the Wrike API responses](responses.md) for the form's definition. Everything
the bot sees, it sees because the request form put it in that folder.
