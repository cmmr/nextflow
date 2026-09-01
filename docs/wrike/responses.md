# Wrike API responses

The live definitions of the "Bioinformatics Pipeline" request form, the
"Nextflow Pipeline Workflow" and its custom statuses, and the custom fields the
bot reads and writes. Kept here so the IDs hardcoded in
[`scripts/wrike_api.sh`](../../scripts/wrike_api.sh) can be checked against what
Wrike actually holds — see [Progress is the task's Status](status.md).

These are captures, so they age. `WRIKE_FORM_ANSWERS` in
[`wrike_api.sh`](../../scripts/wrike_api.sh) is what the system actually reads —
every ID and every allowed answer — and
[the request form's questions](account.md#the-request-forms-questions) is the
summary of it. Re-capture here after changing a field so the two can be compared.

## Set env variables

Sourcing `.env` pulls in both halves: `WRIKE_API_TOKEN` from `secrets/.env`, and
the object IDs used below — `WRIKE_REQUEST_FORM_ID`,
`WRIKE_SPACE_ID` — from `scripts/wrike_api.sh`, along with
`call_wrike_api` itself.

```bash
source /data/prod/nextflow/.env
```


```bash
call_wrike_api GET spaces/$WRIKE_SPACE_ID/customfields | jq -r '.data[] | "\(.id)\t\(.title)"'
```
```json
IEAAIKU5JUANAH3C        Nextflow Pipeline
IEAAIKU5JUANAH3J        Dashboard URL
IEAAIKU5JUANEX3T        Dashboard Expiration
IEAAIKU5JUANE5TN        Dashboard Retention
IEAAIKU5JUANE5UH        Ampliseq --dada_ref_taxonomy
IEAAIKU5JUANE5UV        Ampliseq --qiime_ref_taxonomy
IEAAIKU5JUANE5VD        Ampliseq --kraken2_ref_taxonomy
IEAAIKU5JUANE5VL        Ampliseq --picrust
IEAAIKU5JUANE5VR        Ampliseq --exclude_taxa
IEAAIKU5JUANE5WC        Taxprofiler --hostremoval_reference
IEAAIKU5JUANE5WG        Nextflow Previous Run ID
```


```bash
call_wrike_api GET spaces/$WRIKE_SPACE_ID/customfields
```
```json
{
  "kind": "customfields",
  "data": [
    {
      "id": "IEAAIKU5JUANAH3C",
      "accountId": "IEAAIKU5",
      "title": "Nextflow Pipeline",
      "type": "DropDown",
      "spaceId": "MQAAAAEN9xux",
      "sharedIds": [],
      "sharing": {},
      "settings": {
        "inheritanceType": "All",
        "applicableEntityTypes": [
          "WorkItem"
        ],
        "values": [
          "ampliseq :: 16S full length or variable region amplicons",
          "taxprofiler :: WGS metagenomic profiling",
          "prev_run_id :: process new data using the same settings as before"
        ],
        "options": [
          {
            "value": "ampliseq :: 16S full length or variable region amplicons"
          },
          {
            "value": "taxprofiler :: WGS metagenomic profiling"
          },
          {
            "value": "prev_run_id :: process new data using the same settings as before"
          }
        ],
        "optionColorsEnabled": false,
        "allowOtherValues": true,
        "readOnly": false,
        "allowTime": false
      },
      "description": "",
      "archived": false
    },
    {
      "id": "IEAAIKU5JUANAH3J",
      "accountId": "IEAAIKU5",
      "title": "Dashboard URL",
      "type": "Text",
      "spaceId": "MQAAAAEN9xux",
      "sharedIds": [],
      "sharing": {},
      "settings": {
        "inheritanceType": "All",
        "applicableEntityTypes": [
          "WorkItem"
        ],
        "readOnly": false,
        "allowTime": false
      },
      "description": "",
      "archived": false
    },
    {
      "id": "IEAAIKU5JUANEX3T",
      "accountId": "IEAAIKU5",
      "title": "Dashboard Expiration",
      "type": "Date",
      "spaceId": "MQAAAAEN9xux",
      "sharedIds": [],
      "sharing": {},
      "settings": {
        "inheritanceType": "All",
        "applicableEntityTypes": [
          "WorkItem"
        ],
        "readOnly": false,
        "allowTime": false
      },
      "description": "",
      "archived": false
    },
    {
      "id": "IEAAIKU5JUANE5TN",
      "accountId": "IEAAIKU5",
      "title": "Dashboard Retention",
      "type": "DropDown",
      "spaceId": "MQAAAAEN9xux",
      "sharedIds": [],
      "sharing": {},
      "settings": {
        "inheritanceType": "All",
        "applicableEntityTypes": [
          "WorkItem"
        ],
        "values": [
          "1 Month",
          "3 Months",
          "6 Months",
          "12 Months",
          "24 Months",
          "Unlimited"
        ],
        "options": [
          {
            "value": "1 Month"
          },
          {
            "value": "3 Months"
          },
          {
            "value": "6 Months"
          },
          {
            "value": "12 Months"
          },
          {
            "value": "24 Months"
          },
          {
            "value": "Unlimited"
          }
        ],
        "optionColorsEnabled": false,
        "allowOtherValues": false,
        "readOnly": false,
        "allowTime": false
      },
      "description": "",
      "archived": false
    },
    {
      "id": "IEAAIKU5JUANE5UH",
      "accountId": "IEAAIKU5",
      "title": "Ampliseq --dada_ref_taxonomy",
      "type": "DropDown",
      "spaceId": "MQAAAAEN9xux",
      "sharedIds": [],
      "sharing": {},
      "settings": {
        "inheritanceType": "All",
        "applicableEntityTypes": [
          "WorkItem"
        ],
        "values": [
          "silva=138.2",
          "greengenes2=2024.09",
          "coidb=221216",
          "gtdb=R11-RS232",
          "midori2-co1=gb250",
          "pr2=5.1.0",
          "rdp=18",
          "sbdi-gtdb=R11-RS232-1",
          "unite-alleuk=10.0",
          "unite-fungi=10.0",
          "zehr-nifh=2.5.0"
        ],
        "options": [
          {
            "value": "silva=138.2"
          },
          {
            "value": "greengenes2=2024.09"
          },
          {
            "value": "coidb=221216"
          },
          {
            "value": "gtdb=R11-RS232"
          },
          {
            "value": "midori2-co1=gb250"
          },
          {
            "value": "pr2=5.1.0"
          },
          {
            "value": "rdp=18"
          },
          {
            "value": "sbdi-gtdb=R11-RS232-1"
          },
          {
            "value": "unite-alleuk=10.0"
          },
          {
            "value": "unite-fungi=10.0"
          },
          {
            "value": "zehr-nifh=2.5.0"
          }
        ],
        "optionColorsEnabled": false,
        "allowOtherValues": false,
        "readOnly": false,
        "allowTime": false
      },
      "description": "",
      "archived": false
    },
    {
      "id": "IEAAIKU5JUANE5UV",
      "accountId": "IEAAIKU5",
      "title": "Ampliseq --qiime_ref_taxonomy",
      "type": "DropDown",
      "spaceId": "MQAAAAEN9xux",
      "sharedIds": [],
      "sharing": {},
      "settings": {
        "inheritanceType": "All",
        "applicableEntityTypes": [
          "WorkItem"
        ],
        "values": [
          "silva=138",
          "greengenes2=2024.09"
        ],
        "options": [
          {
            "value": "silva=138"
          },
          {
            "value": "greengenes2=2024.09"
          }
        ],
        "optionColorsEnabled": false,
        "allowOtherValues": false,
        "readOnly": false
      },
      "description": "",
      "archived": false
    },
    {
      "id": "IEAAIKU5JUANE5VD",
      "accountId": "IEAAIKU5",
      "title": "Ampliseq --kraken2_ref_taxonomy",
      "type": "DropDown",
      "spaceId": "MQAAAAEN9xux",
      "sharedIds": [],
      "sharing": {},
      "settings": {
        "inheritanceType": "All",
        "applicableEntityTypes": [
          "WorkItem"
        ],
        "values": [
          "silva=138",
          "rdp=18",
          "greengenes=13.5",
          "standard=20240904"
        ],
        "options": [
          {
            "value": "silva=138"
          },
          {
            "value": "rdp=18"
          },
          {
            "value": "greengenes=13.5"
          },
          {
            "value": "standard=20240904"
          }
        ],
        "optionColorsEnabled": false,
        "allowOtherValues": false,
        "readOnly": false
      },
      "description": "",
      "archived": false
    },
    {
      "id": "IEAAIKU5JUANE5VL",
      "accountId": "IEAAIKU5",
      "title": "Ampliseq --picrust",
      "type": "DropDown",
      "spaceId": "MQAAAAEN9xux",
      "sharedIds": [],
      "sharing": {},
      "settings": {
        "inheritanceType": "All",
        "applicableEntityTypes": [
          "WorkItem"
        ],
        "values": [
          "No",
          "Yes"
        ],
        "options": [
          {
            "value": "No"
          },
          {
            "value": "Yes"
          }
        ],
        "optionColorsEnabled": false,
        "allowOtherValues": false,
        "readOnly": false
      },
      "description": "",
      "archived": false
    },
    {
      "id": "IEAAIKU5JUANE5VR",
      "accountId": "IEAAIKU5",
      "title": "Ampliseq --exclude_taxa",
      "type": "Multiple",
      "spaceId": "MQAAAAEN9xux",
      "sharedIds": [],
      "sharing": {},
      "settings": {
        "inheritanceType": "All",
        "applicableEntityTypes": [
          "WorkItem"
        ],
        "values": [
          "mitochondria",
          "chloroplast",
          "Francisella"
        ],
        "options": [
          {
            "value": "mitochondria"
          },
          {
            "value": "chloroplast"
          },
          {
            "value": "Francisella"
          }
        ],
        "optionColorsEnabled": false,
        "allowOtherValues": false,
        "readOnly": false
      },
      "description": "",
      "archived": false
    },
    {
      "id": "IEAAIKU5JUANE5WC",
      "accountId": "IEAAIKU5",
      "title": "Taxprofiler --hostremoval_reference",
      "type": "DropDown",
      "spaceId": "MQAAAAEN9xux",
      "sharedIds": [],
      "sharing": {},
      "settings": {
        "inheritanceType": "All",
        "applicableEntityTypes": [
          "WorkItem"
        ],
        "values": [
          "None",
          "PhiX",
          "Human + PhiX",
          "Mouse + PhiX"
        ],
        "options": [
          {
            "value": "None"
          },
          {
            "value": "PhiX"
          },
          {
            "value": "Human + PhiX"
          },
          {
            "value": "Mouse + PhiX"
          }
        ],
        "optionColorsEnabled": false,
        "allowOtherValues": false,
        "readOnly": false
      },
      "description": "",
      "archived": false
    },
    {
      "id": "IEAAIKU5JUANE5WG",
      "accountId": "IEAAIKU5",
      "title": "Nextflow Previous Run ID",
      "type": "Text",
      "spaceId": "MQAAAAEN9xux",
      "sharedIds": [],
      "sharing": {},
      "settings": {
        "inheritanceType": "All",
        "applicableEntityTypes": [
          "WorkItem"
        ],
        "readOnly": false
      },
      "description": "",
      "archived": false
    }
  ]
}
```


```bash
call_wrike_api GET request_forms/$WRIKE_REQUEST_FORM_ID
```
```json
{
  "kind": "requestForms",
  "data": [
    {
      "id": "IEAAIKU5LIACYIUI",
      "title": "Nextflow Bioinformatics Pipeline",
      "description": "Run a 16S/WGS Nextflow pipeline on the cluster and generate a dashboard where collaborators can view and download their deliverables.",
      "pages": [
        {
          "id": "IEAAIKU5LIACYIUIH5QTQMJWGM2DKYZNG4ZTENRNGRQTCNRNHE3DCNJNG42TINJYGI4TEOLGMYZA",
          "title": "",
          "fields": [
            {
              "id": "IEAAIKU5LIACYIUIH5SWCM3CMMZTSNZNHEZDIMZNGRRGMNZNMJRDSZBNGBSDKNZZHEYGCNJRGE4Q",
              "title": "Title",
              "type": "TextField",
              "mandatory": true,
              "helperText": "Include the PQ number. Will be visible to collaborators as dashboard's title."
            },
            {
              "id": "IEAAIKU5LIACYIUIH5TDAZRSHA2TOOBNHFQTCNZNGQ2GKMBNHA4WMYZNHEZTKMJRMEZDMMJZGY2Q",
              "title": "Nextflow Pipeline",
              "type": "ComboBox",
              "mandatory": true,
              "helperText": "",
              "items": [
                {
                  "id": "IEAAIKU5LIACYIUIH5RDOYTGMZSWEMRNHE4TSMRNGQZTEMRNMI3TGNRNGJQTGOBSGYYDKOLEGJRA",
                  "title": "ampliseq :: 16S full length or variable region amplicons",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH44DEZJZGI3DEYJNMJSTEZJNGRSTANRNHAZDMYRNGFTDAMBZGRRDMZDEHFTA",
                  "title": "taxprofiler :: WGS metagenomic profiling",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH43DQMBSGUZTGOJNHEYTIZRNGRRTOMZNMFTDGNJNHE4TIYRRMFRWCZBSGQYQ",
                  "title": "prev_run_id :: process new data using the same settings as before",
                  "selectedByDefault": false
                }
              ]
            },
            {
              "id": "IEAAIKU5LIACYIUIH5QTGY3BHEYWEZBNMYZGCMRNGQZGMNZNMFQTAZJNMQ4TMMJVGA4GIODEHFQQ",
              "title": "Attach the sample sheet.",
              "type": "Attachment",
              "mandatory": true,
              "helperText": "Fields: sample, fastq1, fastq2. No header. Tab separated values. Omit fastq2 for single-ended sequencing."
            },
            {
              "id": "IEAAIKU5LIACYIUIH5STEMLGGNRDGNJNMNRDEYRNGQYWCYRNHAYWKMRNGFSDEZBYMEZWKYJTHBQQ",
              "title": "Dashboard Retention",
              "type": "ComboBox",
              "mandatory": true,
              "helperText": "Past this date, the deliverables will be deleted from AWS S3 and the dashboard will be replaced with an \"expired\" placeholder.",
              "items": [
                {
                  "id": "IEAAIKU5LIACYIUIH43TKYZQMNSGIOJNGVSDAMZNGQ4TSMZNHAYDGNRNGRSGEM3EG4ZGCMRQGM4Q",
                  "title": "1 Month",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH43DKYJRGU4TMYRNGRRDGMZNGQ4WIZJNME3TOYJNMJRTQYLEMQ2TSOJVMU2A",
                  "title": "3 Months",
                  "selectedByDefault": true
                },
                {
                  "id": "IEAAIKU5LIACYIUIH5RTQOLBGFQTQOJNGM3WENRNGRQWEZJNMEZTKYRNG42TSNZXG44TIOLFGRSQ",
                  "title": "6 Months",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH43DKMZZGQ2DQNZNGY4WCMBNGQ2TAZJNHAYWMNJNGFQWIOBVGZTDANJXMZRA",
                  "title": "12 Months",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH5QTKNRWGU3WKYJNGJSTIOJNGRRTCMJNMI3GIMRNGZSTKOLDGVRGCZRUMY2Q",
                  "title": "24 Months",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH5SWIZJZMEZDANZNMMYWIZBNGQ3DINRNHAZGINZNMZTGMNJYGYZTINZYMEZQ",
                  "title": "Unlimited",
                  "selectedByDefault": false
                }
              ]
            },
            {
              "id": "IEAAIKU5LIACYIUIH5RWKZTDGJSDQYJNGRRGMNZNGRRWMZJNHFTGIMZNG5TGCMJWMY3WMMDEGVRA",
              "title": "Previous Run ID",
              "type": "TextField",
              "mandatory": true,
              "helperText": "This job will use the exact same settings and software versions."
            },
            {
              "id": "IEAAIKU5LIACYIUIH44GKNTFMFRWIYZNGNSTSYRNGQ2GMMBNHE2DOMBNGU4DQMLEGI2TMZJSMY3A",
              "title": "Host Depletion",
              "type": "ComboBox",
              "mandatory": true,
              "helperText": "Discard reads that map to the organism(s) below.",
              "items": [
                {
                  "id": "IEAAIKU5LIACYIUIH4YWMNJXME2WGNJNMZRTSZRNGQ3GGZBNMI4GEYRNGJRDGYRXGQ3DKNLEMVRA",
                  "title": "None",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH5RTKNJWMFSGINZNGQYWCNJNGQ3DANRNHBRWMZJNGU2DQY3CME2DENDBGZSA",
                  "title": "PhiX",
                  "selectedByDefault": true
                },
                {
                  "id": "IEAAIKU5LIACYIUIH4ZWCMRUMU2DCNJNGU2DMNZNGQ3GEZJNHBSGKYJNMI2DKN3CGJSWCNDCMM3Q",
                  "title": "Human + PhiX",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH5QTSYRVHFRTIOJNMUYGENBNGRSTOZJNHE3WKZRNMQZDMNTBGNQWCYZXGQZA",
                  "title": "Mouse + PhiX",
                  "selectedByDefault": false
                }
              ]
            },
            {
              "id": "IEAAIKU5LIACYIUIH43GGMTDGI2TKNRNHFRTAYJNGRSTMNZNHBQTIYJNGQ4WGZLEHFQTSZJYHEZA",
              "title": "Settings",
              "type": "ComboBox",
              "mandatory": true,
              "helperText": "",
              "items": [
                {
                  "id": "IEAAIKU5LIACYIUIH43DONZVGY2GGMJNGMZTIZBNGQ4WCNBNHE4TGNRNGRSWEMDDMFTGINBWMM3Q",
                  "title": "Default",
                  "selectedByDefault": true
                },
                {
                  "id": "IEAAIKU5LIACYIUIH4ZGKOBXGUYTMOJNGQZTOYRNGRSDEOJNME2TINZNGA2GMMBQGAYTANJZGBSA",
                  "title": "Custom",
                  "selectedByDefault": false
                }
              ]
            },
            {
              "id": "IEAAIKU5LIACYIUIH4ZWGYJWGYZDKZRNG43TMNZNGQZWCNJNMI2DCMBNGRSDMZJWGM2WCNZUGJSQ",
              "title": "Primary ASV Taxonomic Database (DADA2)",
              "type": "ComboBox",
              "mandatory": true,
              "helperText": "Select the reference database used to assign taxonomy to your Amplicon Sequence Variants (ASVs). This parameter (dada_ref_taxonomy) is the core assignment step of the pipeline and directly dictates the taxonomic labels you will see in your primary ASV abundance tables and downstream Phyloseq R objects.",
              "items": [
                {
                  "id": "IEAAIKU5LIACYIUIH4YDAZRSGQ3TSZRNMZRGGOJNGQ3GCYJNHFRTMYZNGM3DONDCMJSGMNRQMQ2A",
                  "title": "silva=138.2",
                  "selectedByDefault": true
                },
                {
                  "id": "IEAAIKU5LIACYIUIH43DKZJZGVSTMMJNGBSGINBNGRSDOMRNHEZDMNZNGZTGGYTGME4GCZRVHA4A",
                  "title": "greengenes2=2024.09",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH42WEZRUGI3DCMJNGFQWGMZNGQ2DEMBNHBQTONRNGE4GMOJXGUZTSMRZGY2Q",
                  "title": "coidb=221216",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH5RDQYLCGA2DCZRNGMZTQMJNGQ2GEZJNHBRDIMRNGM2WGNTCMRRTCOBQGIZQ",
                  "title": "gtdb=R11-RS232",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH4ZTMNRWGU2TGYZNGE3TGZRNGQYDGYRNHBTDANJNHBQTIYJWGA4GMM3CHEZA",
                  "title": "midori2-co1=gb250",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH42WGYZXGJSDKOBNGE4TIYRNGQZDSMRNMFRWGNRNMJRTENZTMM4TMMLEGQZQ",
                  "title": "pr2=5.1.0",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH4YTENRYGE3DQMZNMVSDKYJNGRSTAYRNME4DMYRNGM2DOMTCGY4TKYZSGIZQ",
                  "title": "rdp=18",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH5RWGZBRMQZWIZJNGMZWGZBNGRRTIYRNMI4WGNJNMQZDGYTBGMZGGODEGFRA",
                  "title": "sbdi-gtdb=R11-RS232-1",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH5QTEOLFME3DGZBNGJSDGNBNGQ2WIMBNMFQTOYZNMJTDANLGGFTGGZLBG5SQ",
                  "title": "unite-alleuk=10.0",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH5TGKYZRMQZDKYJNMQ4DEMZNGQZWGMJNMFRWCNZNGQ2GGODEGY4DIYJRGVQQ",
                  "title": "unite-fungi=10.0",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH42GENJRGIYTGNJNGVTGGMRNGRTGENBNHBRDAYZNGQ4DQZRTGI2TEYRSGNSQ",
                  "title": "zehr-nifh=2.5.0",
                  "selectedByDefault": false
                }
              ]
            },
            {
              "id": "IEAAIKU5LIACYIUIH4YTGMBSMZRDAOBNMYZWIZBNGRSDSNZNMI3TEMBNG43TAY3GMU3WGZDFMMZA",
              "title": "Secondary QIIME2 Taxonomic Database",
              "type": "ComboBox",
              "mandatory": true,
              "helperText": "Select the reference database used to train QIIME2's machine-learning taxonomic classifier. This parameter (qiime_ref_taxonomy) runs independently and only affects outputs generated within the QIIME2 ecosystem (such as taxonomy.qza artifacts and interactive barplots), without altering your primary DADA2 ASV tables.",
              "items": [
                {
                  "id": "IEAAIKU5LIACYIUIH44TANLCGA2DSMBNMU3GIOJNGQ2DEMZNMFSGIMBNGA3DEZJRGZTDKMZZGA2A",
                  "title": "silva=138",
                  "selectedByDefault": true
                },
                {
                  "id": "IEAAIKU5LIACYIUIH42TMNZUGQYDCZBNHA2TGMJNGQYGCYJNHFSTONJNMM4WMZBTGEZGCYZZMFTA",
                  "title": "greengenes2=2024.09",
                  "selectedByDefault": false
                }
              ]
            },
            {
              "id": "IEAAIKU5LIACYIUIH5RTCNRSMY3WMZRNME3DMMRNGRSTGMRNMFRTENBNHE4WGNRWHEZGINJVGBQQ",
              "title": "Read-Based Taxonomic Database (Kraken2)",
              "type": "ComboBox",
              "mandatory": true,
              "helperText": "Select the database used to assign taxonomy directly to individual raw sequencing reads using a k-mer approach. This parameter (kraken2_ref_taxonomy) bypasses ASV clustering entirely to generate independent Kraken classification reports, which are highly useful for checking overall sample composition, detecting contamination, or identifying taxa lost during strict denoising.",
              "items": [
                {
                  "id": "IEAAIKU5LIACYIUIH5RWIM3GGE3DCNJNMNRTMYRNGQZDCYJNMJRTKYRNGFTGMMJQGJQWMOJTGBRA",
                  "title": "silva=138",
                  "selectedByDefault": true
                },
                {
                  "id": "IEAAIKU5LIACYIUIH42TCZJSG42GKYJNMNTGMMJNGQZWCNRNMJTGMMRNG5RTKNJRGYZGKMTCMFSQ",
                  "title": "rdp=18",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH43WKM3DGVRDCMBNGMYTQNBNGQYTKOBNMFRDCZJNGBSTCNRXMFRDQYLCME4Q",
                  "title": "greengenes=13.5",
                  "selectedByDefault": false
                },
                {
                  "id": "IEAAIKU5LIACYIUIH42TCOBRMEYGIOJNGY3TINJNGRRTOZJNME2DMZRNMNRTIZJWMVSTKYZYGVTA",
                  "title": "standard=20240904",
                  "selectedByDefault": false
                }
              ]
            },
            {
              "id": "IEAAIKU5LIACYIUIH5STMOBZMJRTCMJNGQYDEYJNGQYWGNBNHFRDONJNHFRGINZVGJSDKOBVGRQQ",
              "title": "Taxa Exclusion Filter",
              "type": "CheckBox",
              "mandatory": false,
              "helperText": "Specify any taxonomic groups you want to explicitly filter out of your analysis. This parameter (--exclude_taxa) defaults to excluding 'Francisella' (our lab uses Francisella DNA as a positive control, which can occasionally cross-contaminate samples during prep). Any taxa listed here will be completely removed from your final ASV abundance tables, Phyloseq objects, and downstream diversity metrics, ensuring your biological interpretations are not skewed by known lab contaminants or off-target sequences.",
              "items": [
                {
                  "id": "IEAAIKU5LIACYIUIH44WEYLEGRRTMYZNG4YTANJNGRSTANBNMJRTINJNGJSTOZTCGU2DENLDMMZQ",
                  "title": "mitochondria",
                  "selectedByDefault": true
                },
                {
                  "id": "IEAAIKU5LIACYIUIH5RTEMBVMZTDAOBNGFTDQMRNGQ4DKNZNMI4WGMJNMRRDQNRZGUYTQNZQGQ2A",
                  "title": "chloroplast",
                  "selectedByDefault": true
                },
                {
                  "id": "IEAAIKU5LIACYIUIH5QTQN3GME2TQNRNGFRGIMZNGQ2WGNBNHBRTMNRNGBQWEZDFGEZTAYJSMEYQ",
                  "title": "Francisella",
                  "selectedByDefault": true
                }
              ]
            },
            {
              "id": "IEAAIKU5LIACYIUIH4ZTENBXGE4DAZRNMY3TIZJNGQ4WEYJNHFRDEMRNMYYDCODCGVTDCMBZMU3A",
              "title": "Functional Profiling (PICRUSt2)",
              "type": "ComboBox",
              "mandatory": true,
              "helperText": "Select whether to infer the functional genetic potential (such as KEGG orthologs and pathways) of your microbial community. This parameter (--picrust) defaults to 'No' because it relies on computationally intensive phylogenetic placement steps that will significantly increase overall pipeline runtime and memory usage. When enabled, it generates supplementary functional abundance tables downstream, but it does not alter your primary ASV or taxonomic composition results.",
              "items": [
                {
                  "id": "IEAAIKU5LIACYIUIH42GEYJZMRQWMYRNMI3WGZRNGQZTSZBNME4TAOBNG4YWMZJWGU4TMYZYMYZA",
                  "title": "No",
                  "selectedByDefault": true
                },
                {
                  "id": "IEAAIKU5LIACYIUIH5STENZTMJSDSYRNGQ3DINZNGQ4DQMRNMJRDCZRNGNSGCZTCGAZGENBVHEZA",
                  "title": "Yes",
                  "selectedByDefault": false
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
call_wrike_api GET "/spaces/$WRIKE_SPACE_ID/workflows"
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
          "id": "IEAAIKU5JMHRVOL4",
          "name": "Running",
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
          "name": "Expired",
          "color": "Brown",
          "group": "Completed",
          "hidden": false
        }
      ],
      "description": ""
    }
  ]
}
```


```bash
call_wrike_api GET "/spaces/$WRIKE_SPACE_ID/workflows"
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
          "name": "Expired",
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


