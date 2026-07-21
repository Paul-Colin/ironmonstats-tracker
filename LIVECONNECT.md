# Connexion à l'application IronMonStats (LiveConnect)

Le tracker peut envoyer **automatiquement** tes runs et ton suivi en direct vers
l'application web **IronMonStats** (stats, top runs, estimateur d'IV, navigateur
de seed, suivi live…). Tout se fait **depuis le tracker** : aucun programme à lancer à
côté.

> Techniquement, c'est l'addon `ironmon_tracker/addons/LiveConnect.lua` qui parle
> directement à l'API de l'application (via `curl`, déjà présent sur Windows 10+).

## Prérequis

- Le tracker installé et fonctionnel dans BizHawk (voir le README principal).
- Un compte sur l'application IronMonStats (instance hébergée, ou locale).

## Étapes

### 1. Générer un token dans l'application

Dans l'application web, ouvre **Profil & réglages → Connexion du tracker → Générer un
token**, puis **copie** le token affiché (il ne s'affiche qu'une fois).

### 2. Ouvrir l'écran LiveConnect dans le tracker

Dans le tracker (fenêtre BizHawk) :

1. Clique sur la **roue crantée** (⚙️) en bas du tracker.
2. Va dans **Extras**.
3. Sur la carte **« IronMonStats »**, clique sur **Configurer**.

### 3. Renseigner l'URL et le token

- **URL de l'app → Définir** : colle l'adresse de l'application.
  - En local : `http://localhost:8080`
  - Sur une instance hébergée : l'URL du site (`https://…`).
- **Token d'accès → Définir** : colle le token généré à l'étape 1.

### 4. Tester puis activer

- Clique sur **Tester**. Après 1–2 secondes, l'état doit afficher
  **« Connecté : \<ton pseudo\> »** en vert.
- Clique sur **Activer l'envoi**.

C'est tout. Joue normalement : à chaque tentative, le tracker envoie le suivi en direct
(pokémon, sac, dresseurs…), le log de seed en début de tentative, et le résumé de la
run à la mort. Rien d'autre à faire.

## Que se passe-t-il ensuite ?

- **En direct** : la page « Live » de l'app se met à jour pendant que tu joues.
- **Début de tentative** : le log randomizer (`.nds.log`) est envoyé et lié à la run →
  le navigateur de seed devient accessible.
- **À la mort / victoire** : la run est importée (`.pastlog` + nombre de tentatives) et
  les statistiques agrégées du tracker (`.statistics`) sont envoyées.

## Vie privée / sécurité

- Le token est stocké en clair dans `savedData/LiveConnect.ini` (fichier local,
  ignoré par git). Tu peux le **révoquer** à tout moment depuis la page Profil de l'app.
- L'addon est **en lecture seule** côté jeu : il n'écrit jamais dans la mémoire du jeu.

## Dépannage

- **« Non configuré »** : URL ou token manquant.
- **« Erreur : acces refuse »** : le token est invalide ou a été révoqué → régénère-en un.
- **« Erreur : pas de reponse »** : l'URL est mauvaise, ou l'application n'est pas
  lancée / accessible.
- **« Désactivé »** : clique sur **Activer l'envoi**.
- Regarde la **console Lua** de BizHawk pour les messages `[LiveConnect]` / `[LiveTracker]`.
