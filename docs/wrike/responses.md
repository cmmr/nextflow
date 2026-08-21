# Wrike API responses

The live definitions of the "Bioinformatics Pipeline" request form, the
"Nextflow Pipeline Workflow" and its custom statuses, and the custom fields the
bot reads and writes. Kept here so the IDs hardcoded in
[`scripts/wrike_api.sh`](../../scripts/wrike_api.sh) can be checked against what
Wrike actually holds — see [Progress is the task's Status](status.md).

## Set env variables

Sourcing `.env` pulls in both halves: `WRIKE_API_TOKEN` from `secrets/.env`, and
the object IDs used below — `WRIKE_NXFPIPE_REQUEST_FORM_ID`,
`WRIKE_NXFPIPE_SPACE_ID` — from `scripts/wrike_api.sh`, along with
`call_wrike_api` itself.

```bash
source /data/prod/nextflow/.env
```


```bash
call_wrike_api GET request_forms/$WRIKE_NXFPIPE_REQUEST_FORM_ID
```
```json
{
  "kind": "requestForms",
  "data": [
    {
      "id": "IEAAIKU5LIACYIUI",
      "title": "Bioinformatics Pipeline",
      "description": "Run a 16S/WGS Nextflow pipeline on the cluster.",
      "pages": [
        {
          "id": "IEAAIKU5LIACYIUIH5QTQMJWGM2DKYZNG4ZTENRNGRQTCNRNHE3DCNJNG42TINJYGI4TEOLGMYZA",
          "title": "",
          "fields": [
            {
              "id": "IEAAIKU5LIACYIUIH5TDAZRSHA2TOOBNHFQTCNZNGQ2GKMBNHA4WMYZNHEZTKMJRMEZDMMJZGY2Q",
              "title": "Select the pipeline to run.",
              "type": "ComboBox",
              "mandatory": true,
              "helperText": "",
              "items": [
                {
                  "id": "IEAAIKU5LIACYIUIH5TDQZRZMEZGGMZNGM4GGNZNGQYTIMBNMI2TCZRNGMYTSZBSGA3TSM3DGM2A",
                  "title": "16Sv4",
                  "selectedByDefault": true
                },
                {
                  "id": "IEAAIKU5LIACYIUIH5RTOYRZGBSDKNBNGMZWMMJNGQ4TKZJNHBQTIMZNGU3WMZRRGZTGIZLEHFSQ",
                  "title": "16Sv1v3",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH4YTMZRZGQ2TMZJNMM3WKMZNGRRDSMRNHFRDIOBNGYYWCNLBGI4GCYLFMM4Q",
                  "title": "16Sv3v5",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH5QTIM3GGRRTSNZNMQ3DSMJNGQYWGMZNHBQWMMBNMNSDONTCME4DIZLGHAYQ",
                  "title": "16Sv5v6",
                  "selectedByDefault": false
                }
              ]
            },
            {
              "id": "IEAAIKU5LIACYIUIH5QTGY3BHEYWEZBNMYZGCMRNGQZGMNZNMFQTAZJNMQ4TMMJVGA4GIODEHFQQ",
              "title": "Attach the sample sheet.",
              "type": "Attachment",
              "mandatory": true,
              "helperText": "Fields: sample, fastq1, fastq2. No header. Tab separated values."
            },
            {
              "id": "IEAAIKU5LIACYIUIH43GEZJUMY2TAMJNMIYDONBNGRSDOMRNMJTDMZRNMQ2WEZBXMQ3TKMZVGEYQ",
              "title": "Ouput",
              "type": "ComboBox",
              "mandatory": true,
              "helperText": "",
              "items": [
                {
                  "id": "IEAAIKU5LIACYIUIH4ZWCOBVG5RGKOBNGE3GCMZNGQYWMMZNMEYDMNZNMJQTINBTMU4TMNRYHFRA",
                  "title": "Dashboard",
                  "selectedByDefault": true
                }
              ]
            }
          ]
        }
      ],
      "spaceId": "MQAAAAEN9xux"
    }
  ]
}
```


```bash
call_wrike_api GET "/spaces/$WRIKE_NXFPIPE_SPACE_ID/workflows"
```
```json
{
  "kind": "workflows",
  "data": [
    {
      "id": "IEAAIKU5K4HRVOKU",
      "spaceId": "MQAAAAEN9xux",
      "name": "Nextflow Pipeline Workflow",
      "standard": false,
      "hidden": false,
      "customStatuses": [
        {
          "standardName": false,
          "standard": false,
          "id": "IEAAIKU5JMHRVOKU",
          "name": "Submitted",
          "color": "Blue",
          "group": "Active",
          "hidden": false
        },
        {
          "standardName": false,
          "standard": false,
          "id": "IEAAIKU5JMHRVOK6",
          "name": "Validating",
          "color": "Blue",
          "group": "Active",
          "hidden": false
        },
        {
          "standardName": false,
          "standard": false,
          "id": "IEAAIKU5JMHRVOLI",
          "name": "Queued",
          "color": "Orange",
          "group": "Active",
          "hidden": false
        },
        {
          "standardName": false,
          "standard": false,
          "id": "IEAAIKU5JMHRXWVK",
          "name": "Initializing",
          "color": "Blue",
          "group": "Active",
          "hidden": false
        },
        {
          "standardName": false,
          "standard": false,
          "id": "IEAAIKU5JMHRVOLS",
          "name": "Pre-Processing",
          "color": "Blue",
          "group": "Active",
          "hidden": false
        },
        {
          "standardName": false,
          "standard": false,
          "id": "IEAAIKU5JMHRVOL4",
          "name": "Running",
          "color": "Blue",
          "group": "Active",
          "hidden": false
        },
        {
          "standardName": false,
          "standard": false,
          "id": "IEAAIKU5JMHRVOMG",
          "name": "Post-Processing",
          "color": "Blue",
          "group": "Active",
          "hidden": false
        },
        {
          "standardName": true,
          "standard": false,
          "id": "IEAAIKU5JMHRVOKV",
          "name": "Completed",
          "color": "Green",
          "group": "Completed",
          "hidden": false
        },
        {
          "standardName": false,
          "standard": false,
          "id": "IEAAIKU5JMHRVOMR",
          "name": "Failed",
          "color": "DarkRed",
          "group": "Completed",
          "hidden": false
        },
        {
          "standardName": false,
          "standard": false,
          "id": "IEAAIKU5JMHRVOM3",
          "name": "Archived",
          "color": "Brown",
          "group": "Completed",
          "hidden": false
        },
        {
          "standardName": true,
          "standard": false,
          "id": "IEAAIKU5JMHRVONH",
          "name": "Cancelled",
          "color": "Gray",
          "group": "Cancelled",
          "hidden": false
        }
      ],
      "description": ""
    }
  ]
}
```


