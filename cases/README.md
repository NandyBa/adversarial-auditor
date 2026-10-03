# cases/ — dossiers clients privés

Tout ce dossier est **ignoré par git** (sauf ce fichier), et le hook
`.githooks/pre-commit` refuse tout commit qui contiendrait un fichier de `cases/`,
même ajouté de force (`git add -f`).

```bash
./tribunal.sh --init-case mon-dossier   # crée cases/mon-dossier/{brief.md,documents/}
./tribunal.sh --case mon-dossier        # résultats dans cases/mon-dossier/outputs/
```

Voir la section « Dossiers privés » du README principal.
