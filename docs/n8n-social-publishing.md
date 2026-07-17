# Auto-publication des articles Ghost vers Facebook & Instagram (n8n)

> **Statut : NON DÉPLOYÉ — plan d'implémentation.** Ce document décrit la
> solution self-hosted retenue (n8n) pour republier automatiquement les
> articles Ghost sur une Page Facebook et un compte Instagram. À dérouler
> le jour où on veut l'activer. Coût : 0 € (hors serveur existant).

## Pourquoi n8n

- Équivalent open-source de Make/Zapier, auto-hébergeable dans le stack
  `~/lfi` existant (comme Umami/DoG) — pas d'abonnement.
- Ghost n'a rien de natif pour FB/Insta ; il expose un webhook
  `post.published`, l'Admin/Content API et un flux RSS — n8n s'y branche.
- Alternatives écartées : Zapier/Make/Metricool/Publer (abonnements),
  IFTTT (faible sur Instagram), micro-service maison (plus de code à
  maintenir pour le même résultat).

## Architecture cible

```
Ghost (post publié)
   │  node "Ghost Trigger" (webhook post.published auto-créé)
   ▼
n8n  (conteneur, réseau lfi_web) ── Caddy TLS ──► n8n.lol-reminder.fr (éditeur web)
   │
   ├─► Facebook Graph API  →  POST /{page-id}/feed        (post lien sur la Page)
   └─► Instagram Graph API →  /media puis /media_publish  (image + légende)
```

## Prérequis

- [ ] **DNS** : `A n8n.lol-reminder.fr → 37.59.103.153` (zone OVH, comme `forum`)
- [ ] **Page Facebook** (l'API ne publie que sur une Page, pas un profil)
- [ ] **Compte Instagram Creator ou Business** (gratuit — conversion dans
      l'app : Paramètres → Compte → Passer à un compte professionnel),
      **relié à la Page Facebook**. Un compte perso ne peut PAS être automatisé.
- [ ] **App Meta** sur developers.facebook.com + token longue durée avec :
      `pages_manage_posts`, `pages_read_engagement`, `instagram_basic`,
      `instagram_content_publish`. Récupérer le **Page ID** et l'**IG User ID**.
      Pour publier sur ses PROPRES comptes, le mode dev suffit — pas d'App Review.

## Déploiement

### 1. Service compose (`docker-compose.override.yml`, serveur)

```yaml
  n8n:
    image: docker.n8n.io/n8nio/n8n:1.x        # épingler une version précise
    restart: unless-stopped
    environment:
      N8N_HOST: n8n.lol-reminder.fr
      N8N_PROTOCOL: https
      N8N_PORT: 5678
      WEBHOOK_URL: https://n8n.lol-reminder.fr/
      N8N_EDITOR_BASE_URL: https://n8n.lol-reminder.fr/
      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}   # openssl rand -hex 24 → .env
      GENERIC_TIMEZONE: Europe/Paris
      TZ: Europe/Paris
      # DB : SQLite par défaut (fichier). n8n ne supporte PAS MySQL — on ne
      # touche pas au MySQL du stack ; data isolée dans le bind mount.
    volumes:
      - ./data/n8n:/home/node/.n8n
    networks:
      - web
```

- `.env` serveur : ajouter `N8N_ENCRYPTION_KEY=<openssl rand -hex 24>`
  (chiffre les credentials stockés — **ne jamais la perdre/changer**).
- Pré-créer `./data/n8n` et `chown 1000:1000` (n8n tourne en uid 1000,
  même piège que `data/ghost-content`).

### 2. Bloc Caddy (`caddy/Caddyfile`)

```
n8n.lol-reminder.fr {
    reverse_proxy n8n:5678        # WebSockets de l'éditeur gérés auto
    encode gzip zstd
    log {
        output stdout
        format console
    }
}
```

⚠️ Appliquer avec `docker compose restart caddy` — le `caddy reload` est
cassé dans ce setup (voir gotcha dans `docs/forum-discourse.md`).

### 3. Sécuriser l'éditeur

Au premier lancement, n8n demande la création d'un compte owner (email +
mot de passe) — le faire immédiatement, l'URL est publique.

## Le workflow n8n

1. **Ghost Trigger** — événement *Post published* (credential = Admin API
   key d'une intégration custom Ghost ; le node crée le webhook lui-même).
2. **Set/Function** — construit le message : `title`, `excerpt`, `url`,
   `feature_image`.
3. **Facebook Graph API** — `POST /{PAGE_ID}/feed` avec `message` + `link`.
4. **Instagram (2 × HTTP Request)** :
   - `POST /{IG_USER_ID}/media` avec `image_url={feature_image}` +
     `caption` → renvoie `creation_id`
   - `POST /{IG_USER_ID}/media_publish` avec `creation_id`
5. Optionnel : node **IF** pour filtrer (ne poster que les posts publics,
   pas les pages), hashtags, délai de publication…

## Contraintes Meta à garder en tête

- Instagram **exige une image** → utiliser la `feature_image` de l'article
  (donc toujours renseigner une image de couverture dans Ghost).
- Les **liens ne sont pas cliquables** dans le fil Instagram → lien en bio.
- Le token longue durée expire (~60 jours) s'il n'est pas de type
  « Page access token » permanent — prévoir le renouvellement ou générer un
  token de Page permanent via l'échange de tokens.

## Ops

```bash
docker compose logs -f n8n         # logs
docker compose up -d n8n           # (re)démarrer / appliquer la config
# backup : ./data/n8n contient la DB SQLite + credentials chiffrés
```
