#!/usr/bin/env bash
# =============================================================================
# test_sandbox.sh — Vérifie la Sandbox Niveau 1 AVANT le premier audit.
# Charge run_sandboxed depuis tribunal.sh puis tente :
#   - une écriture DANS le repo            -> doit RÉUSSIR
#   - une écriture dans /tmp               -> doit être REFUSÉE
#   - une écriture dans ~/Desktop          -> doit être REFUSÉE
#   - une écriture à la racine de $HOME    -> doit être REFUSÉE
#   - une lecture système (/etc/hosts)     -> doit RÉUSSIR
#   - un accès réseau HTTPS (si curl)      -> doit RÉUSSIR (avertissement si hors ligne)
# Code de sortie : 0 si l'isolation est effective, 1 sinon.
# =============================================================================
set -euo pipefail

TRIBUNAL_SANDBOX=1   # le test n'a de sens qu'avec la sandbox active
# shellcheck source=tribunal.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/tribunal.sh"

PASS=0; FAIL=0
pass() { ok "$*"; PASS=$((PASS + 1)); }
fail() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; FAIL=$((FAIL + 1)); }

TOKEN="tribunal_sandbox_probe_$$"

# expect_write_denied <dossier> <libellé>
expect_write_denied() {
  local dir="$1" label="$2" target
  if [ ! -d "$dir" ]; then warn "$label : $dir absent, test ignoré."; return; fi
  target="$dir/$TOKEN"
  if run_sandboxed /bin/sh -c 'echo probe > "$1"' sh "$target" 2>/dev/null; then
    fail "$label : écriture AUTORISÉE dans $dir — la sandbox ne protège pas !"
  else
    pass "$label : écriture refusée dans $dir"
  fi
  # Nettoyage hors sandbox si l'écriture a fui malgré tout.
  rm -f "$target" 2>/dev/null || true
}

log "Sandbox : OS=$SANDBOX_OS, repo=$REPO_DIR"

# 1. Écriture dans le repo
target="$SANDBOX_TMP/$TOKEN"
sandbox_init
if run_sandboxed /bin/sh -c 'echo probe > "$1" && rm -f "$1"' sh "$target"; then
  pass "Repo : écriture autorisée dans $SANDBOX_TMP"
else
  fail "Repo : écriture REFUSÉE dans le repo — les CLI ne pourront pas produire leurs sorties."
fi

# 2-4. Écritures hors repo
expect_write_denied "/tmp"             "/tmp"
expect_write_denied "$HOME/Desktop"    "~/Desktop"
expect_write_denied "$HOME"            "\$HOME"

# 5. Lecture système
if run_sandboxed /bin/cat /etc/hosts > /dev/null; then
  pass "Lecture système autorisée (/etc/hosts)"
else
  fail "Lecture système refusée : les CLI ne pourront pas démarrer."
fi

# 6. Réseau
if command -v curl > /dev/null 2>&1; then
  if run_sandboxed curl -sS -o /dev/null --max-time 10 https://www.example.com 2>/dev/null; then
    pass "Réseau HTTPS autorisé"
  else
    warn "Réseau : échec de la requête HTTPS (hors ligne ?). Les API LLM seront injoignables."
  fi
else
  warn "curl absent : test réseau ignoré."
fi

# Rappel des chemins d'état des CLI ouverts en écriture
if [ -n "$SANDBOX_RW_PATHS" ]; then
  log "Exceptions d'écriture (SANDBOX_RW_PATHS) : $SANDBOX_RW_PATHS"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  ok "Sandbox opérationnelle ($PASS tests réussis). Vous pouvez lancer : ./tribunal.sh --dry-run puis ./tribunal.sh"
  exit 0
fi
die "$FAIL test(s) en échec : NE LANCEZ PAS d'audit tant que l'isolation n'est pas effective."
