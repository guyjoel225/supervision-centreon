#!/usr/bin/env python3
"""Vérifie qu'un playbook n'emploie pas de variable non fournie.

Un playbook qui n'appelle pas un rôle n'a pas ses valeurs par défaut. Si la
variable n'est pas non plus définie dans l'inventaire, elle est indéfinie à
l'exécution, ce que ni ansible-lint ni le contrôle syntaxique ne détectent.

Une variable est considérée fournie si l'une de ces trois conditions tient :
  - le playbook charge le rôle, par « roles: », « include_role » ou un
    « include_vars » pointant sur ses valeurs par défaut ;
  - le playbook importe un autre playbook, qui peut la fournir ;
  - un inventaire la définit dans ses group_vars ou host_vars.
"""
import pathlib
import re
import sys

RACINE = pathlib.Path(__file__).resolve().parent.parent
ROLES = sorted(d.name for d in (RACINE / "roles").iterdir() if d.is_dir())


def variables_de_l_inventaire() -> set[str]:
    """Toutes les variables définies par les inventaires."""
    definies = set()
    for fichier in (RACINE / "inventories").rglob("*.yml"):
        if fichier.name.endswith(".example"):
            continue
        for ligne in fichier.read_text(errors="ignore").splitlines():
            trouve = re.match(r"^\s*([a-z][a-z0-9_]*)\s*:", ligne)
            if trouve:
                definies.add(trouve.group(1))
    return definies


INVENTAIRE = variables_de_l_inventaire()
anomalies = []

for playbook in sorted((RACINE / "playbooks").glob("*.yml")):
    texte = playbook.read_text()

    # Un playbook qui en importe d'autres délègue : on ne juge que les feuilles.
    if re.search(r"import_playbook:", texte):
        continue

    for role in ROLES:
        charge = any(
            re.search(motif, texte)
            for motif in (
                rf"role:\s*{re.escape(role)}\b",
                rf"name:\s*{re.escape(role)}\b",
                rf"roles/{re.escape(role)}/defaults",
            )
        )
        if charge:
            continue

        employees = sorted(
            v
            for v in set(re.findall(rf"\b{re.escape(role)}_[a-z0-9_]+", texte))
            if not v.startswith("_") and v not in INVENTAIRE
        )
        if employees:
            anomalies.append((playbook.name, role, employees))

if anomalies:
    print("Variables employées sans être fournies, ni par un rôle ni par l'inventaire :")
    for nom, role, variables in anomalies:
        print(f"  {nom}, variables du rôle {role} :")
        for v in variables:
            print(f"      {v}")
    print()
    print("Deux corrections possibles : charger les valeurs par défaut du rôle")
    print("dans le playbook, ou définir ces variables dans l'inventaire.")
    sys.exit(1)

print(f"Variables : les {len(INVENTAIRE)} définies par l'inventaire et les rôles chargés couvrent tous les playbooks.")
