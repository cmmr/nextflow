
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

