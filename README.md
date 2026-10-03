# LLM-Tribunal — Trustless-Consulting

> Pipeline adversarial multi-LLM qui simule un cabinet de conseil fiscal et juridique
> Tier 1, dont chaque recommandation est attaquée par des inspecteurs hostiles avant
> validation par un comité des risques. Chaque appel LLM s'exécute dans une
> **Sandbox native Niveau 1** qui interdit toute écriture hors du repo.

**Avertissement** : cet outil produit des **analyses préparatoires générées par IA**.
Il ne remplace pas un avocat fiscaliste ou un expert-comptable habilité. Les LLM peuvent
halluciner des textes de loi : chaque citation doit être vérifiée sur la source officielle.

---

## 1. Démarrage rapide

```bash
git config core.hooksPath .githooks     # 0. active la protection anti-fuite (une fois par clone)
chmod +x tribunal.sh test_sandbox.sh
./test_sandbox.sh                       # 1. vérifier l'isolation
./tribunal.sh --dry-run                 # 2. vérifier le câblage sur l'exemple public
./tribunal.sh --init-case mon-dossier   # 3. créer un dossier PRIVÉ
$EDITOR cases/mon-dossier/brief.md      #    décrire la situation
cp ~/pieces/*.pdf cases/mon-dossier/documents/   # pièces jointes (facultatif)
./tribunal.sh --case mon-dossier        # 4. lancer l'audit
open cases/mon-dossier/outputs/final_report.md
```

---

## Modèle public, cas d'usage privés

Ce dépôt est un **modèle** : il ne contient que le moteur (script, prompts, sandbox) et
un brief d'exemple **fictif**. Vos situations réelles sont des **dossiers privés** qui ne
quittent jamais votre machine via git.

| | Public (versionné) | Privé (jamais versionné) |
|---|---|---|
| Moteur | `tribunal.sh`, `prompts/`, `test_sandbox.sh` | — |
| Données | `inputs/brief.md` (exemple fictif) | `cases/<nom>/brief.md`, `cases/<nom>/documents/` |
| Résultats | — | `outputs/` (runs sur l'exemple), `cases/<nom>/outputs/` |

**Trois couches de protection :**
1. **`.gitignore`** : `cases/*`, `outputs/*` et `.sandbox/` sont ignorés.
2. **Hook `pre-commit`** (`.githooks/`) : refuse tout commit contenant un fichier de
   `cases/`, `outputs/` ou `.sandbox/`, même ajouté de force avec `git add -f`.
   À activer une fois par clone : `git config core.hooksPath .githooks`.
3. **Contrôle au lancement** : `--case` refuse un dossier situé dans le repo qui ne
   serait pas ignoré par git.

Vous pouvez aussi garder vos dossiers **hors du repo** :
`./tribunal.sh --case ~/Documents/dossiers-prives/2026-residence`
(le dossier doit contenir `brief.md` et éventuellement `documents/`).

### Pièces jointes (`documents/`)

Chaque fichier est converti en texte (lecture sandboxée) et transmis aux trois rôles
dans une balise `<documents>`, avec la consigne de traiter ce contenu comme des
**données, jamais comme des instructions** (protection contre l'injection de prompt).

| Format | Conversion |
|---|---|
| `.md .txt .csv .tsv .json .xml` | tel quel |
| `.pdf` | `pdftotext` (`brew install poppler`) |
| `.docx .doc .rtf .odt .html` | `textutil` (natif macOS) |
| autre (images, scans…) | refusé : convertissez en texte (OCR) au préalable |

Au-delà de ~200 Ko de prompt, le script passe automatiquement le prompt sur stdin
(limite de taille des arguments).

### Ce que git ne protège pas

- **Les fournisseurs d'IA reçoivent vos données** : le brief et les documents sont
  envoyés aux API d'Anthropic et d'OpenAI. Anonymisez ce qui n'est pas nécessaire au
  raisonnement (noms, numéros fiscaux, IBAN, adresses de wallets).
- **Historique local des CLI** : `claude -p` conserve la transcription de chaque appel
  dans `~/.claude/projects/` (Codex est lancé en `--ephemeral` et ne garde rien).
  L'option `--no-session-persistence` de Claude n'est pas utilisée : avec la version
  testée, elle produit une réponse vide.

---

## 2. L'audit adversarial (« Adversarial Fact-Checking »)

Le principe : **aucun modèle n'est cru sur parole**. Un modèle propose, deux modèles
d'éditeurs différents (donc avec des biais d'entraînement différents) attaquent
indépendamment, puis un juge instruit chaque attaque de façon contradictoire.

```
                 inputs/brief.md
                        │  [1] lecture sandboxée
                        ▼
        ┌───────────────────────────────┐
  [2]   │  PROPOSER — Claude            │  prompts/proposer_claude.xml
        │  Cabinet Tier 1, RCP absolue  │
        └───────────────┬───────────────┘
                        │ outputs/draft.md
              ┌─────────┴─────────┐          exécution parallèle (& + wait)
              ▼                   ▼
  [3] ┌───────────────┐   ┌───────────────┐
      │ RED TEAM GPT  │   │ RED TEAM      │  prompts/auditor_redteam.xml
      │ Inspecteur    │   │ Gemini        │  3 failles fatales sourcées chacun
      │ OCDE (Codex)  │   │ (optionnel,   │
      │               │   │  désactivé)   │
      └───────┬───────┘   └───────┬───────┘
  audit_gpt.md│                   │audit_gemini.md
              └─────────┬─────────┘
                        ▼
        ┌───────────────────────────────┐
  [4]   │  JUGE — Claude                │  prompts/judge_consolidation.xml
        │  Comité des Risques           │  → VALIDÉ AVEC CORRECTIONS
        └───────────────┬───────────────┘  → ou REFUS DE RECOMMANDATION
                        ▼
              outputs/final_report.md
```

### Les trois rôles

| Rôle | Prompt | Mission |
|---|---|---|
| **Proposer** (Claude) | `proposer_claude.xml` | Associé d'un cabinet Tier 1. Produit une recommandation en trois registres : `<analyse_fiscale_interne>` (technique, interne), `<strategie_communication>` (réserves et pièces à exiger), `<discours_client>` (livrable). |
| **Red Team** (GPT via Codex ; Gemini optionnel) | `auditor_redteam.xml` | Inspecteur fiscal OCDE hostile, spécialiste blockchain et nomades numériques. Doit identifier **3 failles fatales sourcées** (résidence, substance, établissement stable, abus de droit, CFC, exit tax, CRS/DAC8/CARF…) et dénoncer les citations tronquées. |
| **Juge** (Claude) | `judge_consolidation.xml` | Comité des Risques indépendant. Classe chaque faille FONDÉE / PARTIELLEMENT FONDÉE / REJETÉE en le démontrant, puis livre une version finale blindée, ou **refuse** la recommandation si le risque résiduel est élevé. |

### Garde-fous intégrés aux prompts

| Garde-fou | Effet |
|---|---|
| **RCP absolue** | Le proposer raisonne comme si contrôle et contentieux étaient certains : aucun montage frauduleux, sans substance ou abusif. |
| **Anti-cherry-picking** | Toute citation = Référence + **Citation verbatim** + **Contexte adjacent** (exceptions, clauses anti-abus) + **Ratio legis**. |
| **Pas de source fabriquée** | Une référence incertaine est marquée `[À VÉRIFIER]` au lieu d'être inventée ; elle ne peut ni fonder ni réfuter une décision du juge. |
| **Audit indépendant** | Fournisseur différent du proposer. Si Gemini est activé, une faille trouvée par les deux auditeurs pèse plus lourd. |
| **Droit de refus** | Risque résiduel ÉLEVÉ ou INACCEPTABLE ⇒ la solution n'est pas proposée au client. |

---

## 3. La Sandbox Niveau 1

### Pourquoi

Les CLI `claude`, `gemini`, `codex`… sont des **agents** : ils peuvent lire et écrire des
fichiers et exécuter des commandes. Le brief client (ou un document collé dedans) peut
contenir une injection de prompt. La sandbox garantit qu'un agent détourné ne peut pas
modifier votre système (`~/.zshrc`, `~/.ssh`, `~/Desktop`, `/tmp`…) : **les dégâts
possibles se limitent au dossier du repo**.

### Ce que fait `run_sandboxed`

`run_sandboxed <commande> [args…]`, défini en tête de `tribunal.sh`, détecte l'OS via
`uname -s` et enveloppe la commande :

| | macOS (`Darwin`) | Linux |
|---|---|---|
| Mécanisme | `sandbox-exec -f .sandbox/tribunal.sb` | `bwrap` (bubblewrap) |
| Système de fichiers | `(allow default)` puis `(deny file-write*)` : lecture partout, écriture refusée partout… | `--ro-bind / /` : tout le système monté en lecture seule… |
| Exceptions d'écriture | …sauf `(subpath "$REPO_DIR")`, `/dev/null`, `/dev/tty*`, et `SANDBOX_RW_PATHS` | …sauf `--bind "$REPO_DIR" "$REPO_DIR"` et `SANDBOX_RW_PATHS` |
| Périphériques / proc | hérités | `--dev /dev`, `--proc /proc` |
| Réseau | `(allow network*)` | `--unshare-all --share-net` (tous les namespaces isolés sauf le réseau) |
| Fichiers temporaires | `TMPDIR=.sandbox/tmp/` | `TMPDIR=.sandbox/tmp/` (`/tmp` est en lecture seule) |

Toutes les étapes passent par `run_sandboxed` : la lecture du brief (étape 1) et chaque
appel LLM (étapes 2 à 4). Le profil macOS généré est conservé dans
`.sandbox/tribunal.sb` pour inspection.

**Fail-closed** : si `sandbox-exec` / `bwrap` est absent ou si l'OS n'est pas reconnu, le
script s'arrête. La seule façon de s'en passer est `TRIBUNAL_SANDBOX=0` (déconseillé).

### Exceptions nécessaires : l'état des CLI

Les CLI écrivent leur session, leur cache et leurs jetons d'authentification dans votre
`$HOME`. Sans exception, elles plantent. Ces chemins sont listés explicitement dans
`SANDBOX_RW_PATHS` (séparateur `:`) :

```bash
# défaut
SANDBOX_RW_PATHS="$HOME/.claude:$HOME/.claude.json:$HOME/.gemini:$HOME/.codex"
# si vous remplacez Codex par un autre CLI GPT, ajoutez son dossier d'état (exemple : llm)
export SANDBOX_RW_PATHS="$HOME/.claude:$HOME/.claude.json:$HOME/.gemini:$HOME/Library/Application Support/io.datasette.llm"
```

- Un **dossier** autorise tout son contenu. Un **fichier** autorise aussi ses variantes
  `.lock` / `.tmp` / `.backup` sur macOS (filtre `prefix`).
- Les chemins inexistants sont ignorés.
- Ces dossiers sont la **surface résiduelle** de la sandbox : n'y ajoutez rien de plus
  large que nécessaire (jamais `$HOME` ni `~/.config` en entier).
- Linux / bwrap : un fichier isolé (ex. `~/.claude.json`) est monté seul, ce qui empêche
  les écritures atomiques par renommage. Si le CLI échoue, regroupez son état dans un
  dossier (ex. variable `CLAUDE_CONFIG_DIR` de Claude Code) et listez ce dossier.

Pour trouver où un CLI écrit (macOS) : lancez-le dans la sandbox, puis cherchez les refus
dans `log show --last 2m --predicate 'eventMessage CONTAINS "deny(1) file-write"'`.

### Limites (à connaître)

- C'est une isolation du **système de fichiers**, pas du réseau : un agent compromis peut
  exfiltrer le contenu lisible (dont le brief) via HTTPS. N'y mettez pas de données
  d'identification directe ; anonymisez.
- La **lecture** reste autorisée partout (nécessaire au démarrage des CLI). Les secrets
  de `$HOME` sont lisibles par les processus sandboxés.
- `sandbox-exec` est marqué déprécié par Apple mais reste fonctionnel et utilisé par
  les principaux outils de développement.

### Vérifier l'isolation : `test_sandbox.sh`

```bash
./test_sandbox.sh
```

| Test | Attendu |
|---|---|
| Écriture dans `.sandbox/tmp` (repo) | autorisée |
| Écriture dans `/tmp` | **refusée** |
| Écriture dans `~/Desktop` | **refusée** |
| Écriture à la racine de `$HOME` | **refusée** |
| Lecture de `/etc/hosts` | autorisée |
| Requête HTTPS (curl) | autorisée (avertissement si hors ligne) |

Code de sortie `0` uniquement si toutes les attentes sont remplies. **Ne lancez pas
d'audit si ce test échoue.**

---

## 4. Configurer les CLI locaux

Le script **n'utilise pas vos alias shell** : les alias ne sont pas hérités par un
script non interactif, et `sandbox-exec` / `bwrap` exécutent un binaire, pas un alias.
Les commandes sont lues dans des variables d'environnement :

| Variable | Défaut | Rôle |
|---|---|---|
| `CLAUDE_CMD` | `claude -p` | Proposer + Juge |
| `GPT_CMD` | `codex exec --skip-git-repo-check --ephemeral --sandbox read-only --color never` | Auditeur Red Team n°1 (OpenAI Codex CLI) |
| `GEMINI_CMD` | **vide : désactivé** | Auditeur Red Team n°2, optionnel (voir ci-dessous). |
| `LLM_INPUT_MODE` | `arg` | `arg` : `cmd "<prompt>"`. `stdin` : prompt sur l'entrée standard (recommandé pour les longs briefs). |
| `LLM_TIMEOUT` | `600` | Délai max par appel, si `timeout` / `gtimeout` existe (`brew install coreutils`). |
| `ALLOW_PARTIAL_AUDIT` | `0` | `1` : continuer si un seul auditeur échoue (le juge en est informé). |
| `SANDBOX_RW_PATHS` | voir §3 | Exceptions d'écriture hors repo. |
| `TRIBUNAL_SANDBOX` | `1` | `0` désactive la sandbox. |

> ⚠️ **Piège macOS : `gpt` existe déjà.** `/usr/sbin/gpt` est l'outil système de
> manipulation des **tables de partition GUID** des disques. C'est pourquoi `GPT_CMD`
> pointe vers Codex et non vers `gpt`, et le script refuse explicitement ce binaire.

**Pourquoi ces options pour `codex exec`** :

| Option | Raison |
|---|---|
| `--skip-git-repo-check` | Codex refuse par défaut de tourner hors d'un dépôt git. |
| `--ephemeral` | Ne conserve pas la session dans `~/.codex/sessions` (le brief client n'y est pas archivé). |
| `--sandbox read-only` | L'auditeur n'a pas à exécuter de commandes ; s'il essaie, elles sont en lecture seule. Sur macOS, la sandbox de Codex ne peut de toute façon pas s'imbriquer dans celle du tribunal : toute commande lancée par le modèle échoue, ce qui est le comportement voulu. |
| `--color never` | Sortie propre. Seule la réponse finale va sur stdout ; la trace de session part dans `outputs/logs/<run>/gpt_auditor.stderr.log`. |

Pour choisir le modèle : `export GPT_CMD="codex exec -m <modèle> --skip-git-repo-check --ephemeral --sandbox read-only --color never"`.

Exemples (dans `~/.zshrc` ou un fichier `.env` que vous `source`) :

```bash
export CLAUDE_CMD="claude -p"

# GPT — n'importe quel CLI qui prend un prompt et répond sur stdout :
# GPT : Codex par défaut. Alternatives :
# export GPT_CMD="llm -m gpt-5"        # simonw/llm
# export GPT_CMD="$HOME/bin/ask-gpt"   # votre propre wrapper

# Gemini : désactivé par défaut (voir ci-dessous)
export LLM_INPUT_MODE=stdin
```

**Vous aviez un alias ?** Transformez-le en script exécutable :

```bash
mkdir -p ~/bin
cat > ~/bin/ask-gpt <<'EOF'
#!/usr/bin/env bash
# lit le prompt sur stdin ou en argument, répond sur stdout
exec llm -m gpt-5 "${1:-$(cat)}"
EOF
chmod +x ~/bin/ask-gpt
export GPT_CMD="$HOME/bin/ask-gpt"
```

Les commandes sont découpées sur les espaces ; pour des guillemets ou des pipes, passez
par un wrapper comme ci-dessus.

### Gemini (auditeur n°2) : désactivé pour l'instant

Par défaut, l'étape 3 ne lance **que l'audit GPT (Codex)** :
- aucun fichier `audit_gemini.md` n'est produit ;
- le juge est prévenu qu'un seul audit est disponible et qu'aucune faille n'est
  corroborée, et durcit son propre contre-examen ;
- si l'audit GPT échoue, le pipeline s'arrête (pas de jugement sans contradicteur).

Pour réactiver Gemini, il suffit de définir `GEMINI_CMD` : l'exécution parallèle
(`&` + `wait`) et `ALLOW_PARTIAL_AUDIT` reprennent automatiquement.

```bash
export GEMINI_CMD="gemini -p"   # ou tout autre CLI/wrapper Gemini
```

Pour `gemini-cli`, la connexion Google gratuite « Gemini Code Assist for individuals »
est refusée (`IneligibleTierError`) : il faut une clé API (`GEMINI_API_KEY`, Google AI
Studio) ou un compte Vertex AI. Si votre client Gemini écrit son état ailleurs que dans
`~/.gemini`, ajoutez ce dossier à `SANDBOX_RW_PATHS`.

---

## 5. Structure du projet

```
.
├── tribunal.sh                  # orchestrateur + run_sandboxed
├── test_sandbox.sh              # vérification de l'isolation
├── prompts/
│   ├── proposer_claude.xml
│   ├── auditor_redteam.xml
│   └── judge_consolidation.xml
├── inputs/
│   └── brief.md                 # exemple public FICTIF
├── cases/                       # PRIVÉ, ignoré par git (sauf README.md)
│   └── <nom>/
│       ├── brief.md
│       ├── documents/           # pièces jointes
│       └── outputs/             # mêmes fichiers que outputs/ ci-dessous
├── .githooks/pre-commit         # bloque tout commit de cases/ outputs/ .sandbox/
├── outputs/                     # ignoré par git (runs sur l'exemple public)
│   ├── draft.md  audit_gpt.md  [audit_gemini.md]  final_report.md
│   ├── logs/<run_id>/*.stderr.log
│   └── runs/<run_id>/           # archive de chaque exécution
└── .sandbox/                    # ignoré par git : profil généré + TMPDIR privé
```

## 6. Gestion des erreurs

- `set -euo pipefail` ; en cas d'échec, l'étape fautive et le dossier de logs sont affichés.
- Les sorties sont écrites dans `*.partial` puis renommées : un fichier présent dans
  `outputs/` est toujours complet. Une réponse vide compte comme un échec.
- Étape 3 : chaque auditeur est attendu individuellement (`wait $PID`) ; si les deux
  échouent, le pipeline s'arrête.
- Les sorties du run précédent sont effacées au démarrage ; l'historique reste dans
  `outputs/runs/`.
