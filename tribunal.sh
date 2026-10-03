#!/usr/bin/env bash
# =============================================================================
# LLM-Tribunal (Trustless-Consulting)
# Pipeline adversarial : Proposer (Claude) -> Red Team (GPT || Gemini) -> Juge (Claude)
# Chaque appel LLM s'exécute dans une SANDBOX NIVEAU 1 :
#   macOS : sandbox-exec (écriture interdite hors du repo, réseau autorisé)
#   Linux : bwrap        (/ en lecture seule, repo en lecture-écriture, réseau partagé)
#
# Usage :
#   ./tribunal.sh                      # utilise inputs/brief.md
#   ./tribunal.sh -b chemin/brief.md   # brief alternatif
#   ./tribunal.sh --dry-run            # LLM simulés (dans la sandbox), aucun appel réseau
#
# Configuration (variables d'environnement, voir README) :
#   CLAUDE_CMD   (défaut: "claude -p")
#   GPT_CMD      (défaut: "codex exec --skip-git-repo-check --ephemeral --sandbox read-only --color never")
#   GEMINI_CMD   (défaut: vide = auditeur Gemini DÉSACTIVÉ ; ex. "gemini -p" pour l'activer)
#   LLM_INPUT_MODE      arg|stdin  (défaut: arg)   prompt en argument ou sur stdin
#   LLM_TIMEOUT         secondes   (défaut: 600)   nécessite timeout/gtimeout
#   ALLOW_PARTIAL_AUDIT 0|1        (défaut: 0)     continuer si un seul auditeur échoue
#   SANDBOX_RW_PATHS    liste séparée par ':' de chemins hors repo accessibles en
#                       écriture (état des CLI). Défaut: ~/.claude:~/.claude.json:~/.gemini:~/.codex
#   TRIBUNAL_SANDBOX    1|0        (défaut: 1)     0 = désactive la sandbox (déconseillé)
# Compatible bash 3.2 (macOS). Ce fichier peut être sourcé (test_sandbox.sh).
# =============================================================================

set -euo pipefail

# --- Chemins (résolus physiquement : la sandbox raisonne sur les chemins réels) ---
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROMPTS_DIR="$REPO_DIR/prompts"
OUTPUTS_DIR="$REPO_DIR/outputs"
SANDBOX_DIR="$REPO_DIR/.sandbox"          # profil, TMPDIR privé, fichiers de travail
SANDBOX_TMP="$SANDBOX_DIR/tmp"
BRIEF_FILE="$REPO_DIR/inputs/brief.md"

# --- Configuration ------------------------------------------------------------
CLAUDE_CMD="${CLAUDE_CMD:-claude -p}"
GPT_CMD="${GPT_CMD:-codex exec --skip-git-repo-check --ephemeral --sandbox read-only --color never}"
GEMINI_CMD="${GEMINI_CMD:-}"
LLM_INPUT_MODE="${LLM_INPUT_MODE:-arg}"
LLM_TIMEOUT="${LLM_TIMEOUT:-600}"
ALLOW_PARTIAL_AUDIT="${ALLOW_PARTIAL_AUDIT:-0}"
SANDBOX_RW_PATHS="${SANDBOX_RW_PATHS-$HOME/.claude:$HOME/.claude.json:$HOME/.gemini:$HOME/.codex}"
TRIBUNAL_SANDBOX="${TRIBUNAL_SANDBOX:-1}"
DRY_RUN=0

# --- Affichage ----------------------------------------------------------------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""
fi
log()  { printf '%s[%s]%s %s\n' "$C_BLU" "$(date +%H:%M:%S)" "$C_RST" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# =============================================================================
# SANDBOX NIVEAU 1
# =============================================================================
SANDBOX_OS="$(uname -s)"
SANDBOX_PROFILE="$SANDBOX_DIR/tribunal.sb"
SANDBOX_READY=0

# Chaîne SBPL : refuse les chemins contenant " ou \ (injection dans le profil).
_sb_str() {
  case "$1" in *'"'*|*'\'*) die "Chemin non supporté dans la sandbox : $1" ;; esac
  printf '"%s"' "$1"
}

# Résout un chemin en chemin physique (les symlinks comme /tmp -> /private/tmp
# doivent être résolus pour que sandbox-exec les reconnaisse).
_realpath() {
  if [ -d "$1" ]; then (cd "$1" && pwd -P)
  else printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"; fi
}

# Prépare la sandbox (une seule fois) : TMPDIR privé + profil macOS.
sandbox_init() {
  [ "$SANDBOX_READY" -eq 1 ] && return 0
  mkdir -p "$SANDBOX_TMP"

  if [ "$TRIBUNAL_SANDBOX" = "0" ]; then
    warn "SANDBOX DÉSACTIVÉE (TRIBUNAL_SANDBOX=0) : les CLI ont un accès complet au disque."
    SANDBOX_READY=1; return 0
  fi

  case "$SANDBOX_OS" in
    Darwin)
      command -v sandbox-exec >/dev/null 2>&1 || die "sandbox-exec introuvable."
      local p rp extra=""
      local IFS=':'
      for p in $SANDBOX_RW_PATHS; do
        [ -n "$p" ] || continue
        [ -e "$p" ] || continue
        rp="$(_realpath "$p")"
        if [ -d "$rp" ]; then extra="$extra
  (subpath $(_sb_str "$rp"))"
        else
          # Fichier : préfixe pour couvrir les écritures atomiques (.lock, .tmp, .backup).
          extra="$extra
  (prefix $(_sb_str "$rp"))"
        fi
      done
      unset IFS
      cat > "$SANDBOX_PROFILE" <<EOF
;; Généré par tribunal.sh — Sandbox Niveau 1 (macOS)
(version 1)
;; Lecture système, exécution de processus, IPC : autorisés.
(allow default)
;; Toute écriture sur le disque est interdite…
(deny file-write*)
;; …sauf dans le repo, les pseudo-périphériques et l'état explicite des CLI.
(allow file-write*
  (subpath $(_sb_str "$REPO_DIR"))
  (literal "/dev/null") (literal "/dev/zero") (literal "/dev/random") (literal "/dev/urandom")
  (literal "/dev/tty") (regex #"^/dev/ttys[0-9]+$") (regex #"^/dev/fd/[0-9]+$")$extra)
;; Les CLI LLM ont besoin du réseau pour joindre leurs API.
(allow network*)
EOF
      ;;
    Linux)
      command -v bwrap >/dev/null 2>&1 \
        || die "bwrap introuvable (apt install bubblewrap / dnf install bubblewrap)."
      ;;
    *) die "OS non supporté par la sandbox : $SANDBOX_OS (TRIBUNAL_SANDBOX=0 pour forcer, déconseillé)." ;;
  esac
  SANDBOX_READY=1
}

# run_sandboxed <cmd> [args...] : exécute une commande isolée du système de fichiers.
# stdin/stdout/stderr sont hérités (les redirections de l'appelant fonctionnent).
run_sandboxed() {
  sandbox_init
  if [ "$TRIBUNAL_SANDBOX" = "0" ]; then
    TMPDIR="$SANDBOX_TMP/" "$@"; return
  fi

  case "$SANDBOX_OS" in
    Darwin)
      TMPDIR="$SANDBOX_TMP/" sandbox-exec -f "$SANDBOX_PROFILE" "$@"
      ;;
    Linux)
      local -a bw
      bw=(bwrap
          --ro-bind / /
          --dev /dev
          --proc /proc
          --bind "$REPO_DIR" "$REPO_DIR"
          --unshare-all --share-net
          --die-with-parent
          --setenv TMPDIR "$SANDBOX_TMP/")
      local p IFS=':'
      for p in $SANDBOX_RW_PATHS; do
        [ -n "$p" ] && [ -e "$p" ] && bw=("${bw[@]}" --bind "$p" "$p")
      done
      unset IFS
      "${bw[@]}" -- "$@"
      ;;
  esac
}

# Si le fichier est sourcé (ex. test_sandbox.sh), on s'arrête ici : seules les
# fonctions et la configuration sont chargées.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi

# =============================================================================
# PIPELINE
# =============================================================================
PROMPT_PROPOSER="$PROMPTS_DIR/proposer_claude.xml"
PROMPT_AUDITOR="$PROMPTS_DIR/auditor_redteam.xml"
PROMPT_JUDGE="$PROMPTS_DIR/judge_consolidation.xml"

DRAFT="$OUTPUTS_DIR/draft.md"
AUDIT_GPT="$OUTPUTS_DIR/audit_gpt.md"
AUDIT_GEMINI="$OUTPUTS_DIR/audit_gemini.md"
FINAL="$OUTPUTS_DIR/final_report.md"

CURRENT_STEP="initialisation"
on_error() {
  printf '%s[FAIL]%s Échec à l étape « %s » (code %s). Logs : %s\n' \
    "$C_RED" "$C_RST" "$CURRENT_STEP" "$1" "${LOG_DIR:-$OUTPUTS_DIR/logs}" >&2
}
trap 'rc=$?; [ "$rc" -ne 0 ] && on_error "$rc"' EXIT

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    -b|--brief) [ $# -ge 2 ] || die "--brief requiert un chemin"; BRIEF_FILE="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage ;;
    *)          die "Argument inconnu : $1 (voir --help)" ;;
  esac
done

TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"; fi

# Vérifie que la commande existe et n'est pas un homonyme système dangereux.
require_cmd() {
  local label="$1" cmd="$2" bin path
  [ -n "$cmd" ] || die "${label}_CMD n'est pas défini (voir README §4)."
  bin="${cmd%% *}"
  path="$(command -v "$bin" 2>/dev/null)" \
    || die "$label : commande « $bin » introuvable. Définissez ${label}_CMD (voir README)."
  case "$path" in
    /usr/sbin/gpt|/sbin/gpt)
      die "$label : « $path » est l'outil système de tables de partition GUID, pas un LLM. Définissez GPT_CMD." ;;
  esac
}

# Simulateur pour --dry-run, exécuté DANS la sandbox : $1 = rôle, prompt sur stdin.
MOCK_SCRIPT='
bytes=$(wc -c | tr -d " ")
printf "# [DRY-RUN] Réponse simulée — %s\n\nPrompt reçu : %s octets.\n" "$1" "$bytes"
case "$1" in
  proposer) printf "\n<analyse_fiscale_interne>…</analyse_fiscale_interne>\n<strategie_communication>…</strategie_communication>\n<discours_client>…</discours_client>\n" ;;
  judge)    printf "\n## 1. Décision du Comité\n- **Décision** : REFUS DE RECOMMANDATION\n" ;;
esac'

# call_llm <NOM> <ROLE> <COMMANDE> <FICHIER_PROMPT> <FICHIER_SORTIE>
# Écrit dans <sortie>.partial puis renomme : un fichier présent est toujours complet.
call_llm() {
  local name="$1" role="$2" cmd="$3" prompt_file="$4" out="$5"
  local tmp_out="$out.partial" err_log="$LOG_DIR/${name}.stderr.log"
  local -a argv tprefix
  tprefix=()

  if [ "$DRY_RUN" -eq 1 ]; then
    run_sandboxed /bin/sh -c "$MOCK_SCRIPT" mock "$role" \
      < "$prompt_file" > "$tmp_out" 2> "$err_log" || { rm -f "$tmp_out"; return 1; }
  else
    read -r -a argv <<< "$cmd"
    if [ -n "$TIMEOUT_BIN" ]; then tprefix=("$TIMEOUT_BIN" "$LLM_TIMEOUT"); fi
    case "$LLM_INPUT_MODE" in
      arg)
        run_sandboxed ${tprefix[@]+"${tprefix[@]}"} "${argv[@]}" "$(cat "$prompt_file")" \
          < /dev/null > "$tmp_out" 2> "$err_log" || { rm -f "$tmp_out"; return 1; }
        ;;
      stdin)
        run_sandboxed ${tprefix[@]+"${tprefix[@]}"} "${argv[@]}" \
          < "$prompt_file" > "$tmp_out" 2> "$err_log" || { rm -f "$tmp_out"; return 1; }
        ;;
      *) echo "LLM_INPUT_MODE invalide : $LLM_INPUT_MODE (arg|stdin)" >> "$err_log"; return 2 ;;
    esac
  fi

  if [ ! -s "$tmp_out" ]; then
    echo "$name : réponse vide" >> "$err_log"
    rm -f "$tmp_out"
    return 1
  fi
  mv "$tmp_out" "$out"
}

# wrap <balise> <fichier> : encapsule un fichier dans une balise XML.
wrap() { printf '<%s>\n' "$1"; cat "$2"; printf '\n</%s>\n\n' "$1"; }

# =============================================================================
# ÉTAPE 0 — Pré-requis
# =============================================================================
CURRENT_STEP="pré-requis"
for f in "$PROMPT_PROPOSER" "$PROMPT_AUDITOR" "$PROMPT_JUDGE"; do
  [ -f "$f" ] || die "Prompt manquant : $f"
done
if [ "$DRY_RUN" -eq 0 ]; then
  require_cmd CLAUDE "$CLAUDE_CMD"
  require_cmd GPT    "$GPT_CMD"
  [ -z "$GEMINI_CMD" ] || require_cmd GEMINI "$GEMINI_CMD"
  [ -n "$TIMEOUT_BIN" ] || warn "Ni 'timeout' ni 'gtimeout' : aucun délai max (brew install coreutils)."
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
LOG_DIR="$OUTPUTS_DIR/logs/$RUN_ID"
WORK_DIR="$SANDBOX_DIR/run-$RUN_ID"
mkdir -p "$OUTPUTS_DIR" "$LOG_DIR" "$WORK_DIR"
trap 'rc=$?; rm -rf "$WORK_DIR"; [ "$rc" -ne 0 ] && on_error "$rc"' EXIT

sandbox_init
rm -f "$DRAFT" "$AUDIT_GPT" "$AUDIT_GEMINI" "$FINAL"
log "Run $RUN_ID — sandbox: $( [ "$TRIBUNAL_SANDBOX" = 0 ] && echo DÉSACTIVÉE || echo "$SANDBOX_OS niveau 1" )$( [ "$DRY_RUN" -eq 1 ] && echo ' — DRY-RUN' )"

# =============================================================================
# ÉTAPE 1 — Lecture du brief (sandboxée)
# =============================================================================
CURRENT_STEP="1/4 lecture du brief"
log "Étape $CURRENT_STEP : $BRIEF_FILE"
[ -f "$BRIEF_FILE" ] || die "Brief introuvable : $BRIEF_FILE"
BRIEF="$WORK_DIR/brief.md"
run_sandboxed /bin/cat "$BRIEF_FILE" > "$BRIEF" || die "Lecture sandboxée du brief impossible."
[ -s "$BRIEF" ] || die "Brief vide : $BRIEF_FILE"
ok "Brief chargé ($(wc -c < "$BRIEF" | tr -d ' ') octets)"

# =============================================================================
# ÉTAPE 2 — Proposer (Claude) -> outputs/draft.md
# =============================================================================
CURRENT_STEP="2/4 proposition (Claude)"
log "Étape $CURRENT_STEP"
P_PROPOSER="$WORK_DIR/proposer.prompt"
{
  cat "$PROMPT_PROPOSER"; printf '\n\n'
  wrap brief "$BRIEF"
  printf 'Produisez maintenant votre recommandation en respectant strictement le format de sortie obligatoire.\n'
} > "$P_PROPOSER"

call_llm claude_proposer proposer "$CLAUDE_CMD" "$P_PROPOSER" "$DRAFT" \
  || die "Claude (proposer) a échoué — voir $LOG_DIR/claude_proposer.stderr.log"
for tag in analyse_fiscale_interne strategie_communication discours_client; do
  grep -q "<$tag>" "$DRAFT" || warn "Balise <$tag> absente du brouillon (format non respecté)."
done
ok "Brouillon -> outputs/draft.md"

# =============================================================================
# ÉTAPE 3 — Red Team en PARALLÈLE (GPT || Gemini)
# =============================================================================
if [ -n "$GEMINI_CMD" ]; then
  CURRENT_STEP="3/4 audit red team (GPT || Gemini)"
else
  CURRENT_STEP="3/4 audit red team (GPT seul — Gemini désactivé)"
fi
log "Étape $CURRENT_STEP"
P_AUDITOR="$WORK_DIR/auditor.prompt"
{
  cat "$PROMPT_AUDITOR"; printf '\n\n'
  wrap brief "$BRIEF"
  wrap draft "$DRAFT"
  printf 'Auditez ce brouillon. Livrez vos 3 failles fatales sourcées au format obligatoire.\n'
} > "$P_AUDITOR"

call_llm gpt_auditor auditor "$GPT_CMD" "$P_AUDITOR" "$AUDIT_GPT" & PID_GPT=$!
if [ -n "$GEMINI_CMD" ]; then
  call_llm gemini_auditor auditor "$GEMINI_CMD" "$P_AUDITOR" "$AUDIT_GEMINI" & PID_GEMINI=$!
  log "Auditeurs lancés (GPT pid=$PID_GPT, Gemini pid=$PID_GEMINI), attente…"
else
  log "Auditeur lancé (GPT pid=$PID_GPT), attente…"
fi

# `wait <pid> || …` neutralise set -e et récupère chaque code de sortie.
RC_GPT=0; wait "$PID_GPT" || RC_GPT=$?
if [ "$RC_GPT" -eq 0 ]; then ok "Audit GPT -> outputs/audit_gpt.md"
else warn "Audit GPT en échec (code $RC_GPT) — $LOG_DIR/gpt_auditor.stderr.log"; fi

if [ -z "$GEMINI_CMD" ]; then
  # Auditeur unique : son échec est bloquant.
  [ "$RC_GPT" -eq 0 ] || die "L'auditeur GPT a échoué : impossible de juger sans contradiction."
  RC_GEMINI=-1
else
  RC_GEMINI=0; wait "$PID_GEMINI" || RC_GEMINI=$?
  if [ "$RC_GEMINI" -eq 0 ]; then ok "Audit Gemini -> outputs/audit_gemini.md"
  else warn "Audit Gemini en échec (code $RC_GEMINI) — $LOG_DIR/gemini_auditor.stderr.log"; fi
fi

if [ "$RC_GEMINI" -ge 0 ] && [ "$RC_GPT" -ne 0 ] && [ "$RC_GEMINI" -ne 0 ]; then
  die "Les deux auditeurs ont échoué : impossible de juger sans contradiction."
fi
if [ "$RC_GEMINI" -ge 0 ] && { [ "$RC_GPT" -ne 0 ] || [ "$RC_GEMINI" -ne 0 ]; }; then
  [ "$ALLOW_PARTIAL_AUDIT" = "1" ] \
    || die "Un auditeur a échoué. Relancez, ou ALLOW_PARTIAL_AUDIT=1 pour continuer en mode dégradé."
  warn "Mode dégradé : un seul audit disponible."
  MISSING="[AUDIT INDISPONIBLE — cet auditeur a échoué. Le Comité doit en tenir compte et durcir son appréciation.]"
  if [ "$RC_GPT" -ne 0 ]; then echo "$MISSING" > "$AUDIT_GPT"; fi
  if [ "$RC_GEMINI" -ne 0 ]; then echo "$MISSING" > "$AUDIT_GEMINI"; fi
fi

# =============================================================================
# ÉTAPE 4 — Juge / Consolidation (Claude) -> outputs/final_report.md
# =============================================================================
CURRENT_STEP="4/4 jugement (Claude)"
log "Étape $CURRENT_STEP"
P_JUDGE="$WORK_DIR/judge.prompt"
{
  cat "$PROMPT_JUDGE"; printf '\n\n'
  wrap brief        "$BRIEF"
  wrap draft        "$DRAFT"
  wrap audit_gpt    "$AUDIT_GPT"
  if [ "$RC_GEMINI" -ge 0 ]; then
    wrap audit_gemini "$AUDIT_GEMINI"
  else
    printf 'Note : un seul audit Red Team indépendant (GPT) est disponible pour ce dossier. Aucune faille ne peut être corroborée par un second auditeur.\n\n'
  fi
  printf 'Instruisez chaque faille, puis rendez votre décision au format obligatoire.\n'
} > "$P_JUDGE"

call_llm claude_judge judge "$CLAUDE_CMD" "$P_JUDGE" "$FINAL" \
  || die "Claude (juge) a échoué — voir $LOG_DIR/claude_judge.stderr.log"
ok "Rapport final -> outputs/final_report.md"

# =============================================================================
# Archivage
# =============================================================================
CURRENT_STEP="archivage"
ARCHIVE_DIR="$OUTPUTS_DIR/runs/$RUN_ID"
mkdir -p "$ARCHIVE_DIR"
cp "$BRIEF" "$DRAFT" "$AUDIT_GPT" "$FINAL" "$ARCHIVE_DIR/"
[ ! -f "$AUDIT_GEMINI" ] || cp "$AUDIT_GEMINI" "$ARCHIVE_DIR/"

DECISION="$(grep -m1 -oE 'VALIDÉ AVEC CORRECTIONS|REFUS DE RECOMMANDATION' "$FINAL" || echo 'NON DÉTECTÉE')"
log "Décision du Comité : $DECISION"
ok "Run archivé dans outputs/runs/$RUN_ID"
