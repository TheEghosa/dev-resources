# Self-hosted n8n on Oracle Cloud, behind Cloudflare

This folder sets up the free Community Edition of n8n on an Oracle Cloud "Always Free" server and publishes it at an address on your own domain, such as `n8n.yourdomain.com`. Cloudflare sits in front of it and does two jobs. Cloudflare Tunnel carries visitors to the server without opening any ports, and Cloudflare Access puts a login screen in front of the n8n editor, so only you (and Claude, using a service token) can reach it.

The guide is written for someone who has never used a server before, so each step says what to click and why it matters. Set aside about an hour for the first run, most of which goes on creating accounts.

## How the pieces fit together

```
Your browser  -->  Cloudflare (login check)          -->  Tunnel  -->  Oracle server  -->  n8n
Claude        -->  Cloudflare (service token check)  -->  Tunnel  -->  Oracle server  -->  n8n
Webhooks      -->  Cloudflare (no login on /webhook)  -->  Tunnel  -->  Oracle server  -->  n8n
```

Everything on the server runs in Docker, which packages n8n and the Cloudflare connector as two small, self-contained programs. The file `compose.yaml` describes them, `setup.sh` installs and starts them, and `check-connection.sh` is the script Claude runs at the end to confirm it can reach your n8n.

## What you need before starting

| You need | Why |
|---|---|
| Your Cloudflare account, with your domain already on it | The tunnel and the login screen both run on your domain |
| An Oracle Cloud account (step 1 creates it) | The free server n8n runs on |
| A payment card | Oracle asks for one to verify your identity, even for the free tier |
| A computer with Windows 10 or 11, or a Mac | You use its built-in terminal to connect to the server once |
| The address you want for n8n, such as `n8n.yourdomain.com` | Decide it now, because several steps ask for it |

## Step 1: Create your Oracle Cloud account

Sign up at [oracle.com/cloud/free](https://www.oracle.com/cloud/free/). Pay close attention when it asks for your **home region**, because the choice is permanent and Oracle only gives you free servers in that region. Pick the region nearest to you, or nearest to the services your workflows will talk to.

When the account is ready, we recommend upgrading it to **Pay As You Go** (in the Oracle console under Billing). The reason is a rule in Oracle's own documentation: a free server can be reclaimed if, over seven days, its processor, network and memory use all stay below 20 percent, and a quiet n8n server can easily sit below all three. Oracle's stated remedy is the upgrade, and you are not charged while your usage stays inside the free allowance. After upgrading, create a budget alert under Billing, set to a small amount such as 1 dollar, so you hear about any charge the day it appears.

## Step 2: Create the server

In the Oracle console, open the menu and go to **Compute**, then **Instances**, then **Create instance**. Oracle changes its screens from time to time, so a label may differ slightly from what is written here.

1. **Name:** `n8n`.
2. **Image:** select **Change image**, pick **Ubuntu**, then the newest **Canonical Ubuntu** release marked as supported (24.04 at the time of writing).
3. **Shape:** select **Change shape**, choose **Ampere**, then **VM.Standard.A1.Flex**. Set **2 OCPUs** and **12 GB** of memory, which is the whole free allowance and far more than n8n needs.
4. **Networking:** keep the defaults, which create a new network for you. Make sure **Automatically assign public IPv4 address** is switched on, since you need that address to connect in step 3.
5. **SSH keys:** choose **Generate a key pair for me**, then select **Save private key**. Keep that downloaded file safe, because it is the only way into the server.
6. **Boot volume:** leave the default size. Oracle's free allowance covers 200 GB of storage in total.

Select **Create**. If Oracle reports that it is **out of capacity**, that means its free Ampere servers in your region are all in use at that moment. Try a different **availability domain** in the placement section, or try again a few hours later; people commonly need several attempts.

When the server shows as **Running**, copy its **Public IP address** from the instance page.

## Step 3: Connect to the server

You only type commands into the server once, in step 6, but this step proves the connection works first.

**On Windows**, open **PowerShell** from the Start menu. Windows is strict about who may read the key file, so first run this line, replacing the path with wherever your key was downloaded:

```powershell
icacls "$HOME\Downloads\ssh-key-2026-10-07.key" /inheritance:r /grant:r "$($env:USERNAME):(R)"
```

Then connect, replacing the path and the IP address with yours:

```powershell
ssh -i "$HOME\Downloads\ssh-key-2026-10-07.key" ubuntu@203.0.113.10
```

**On a Mac**, open **Terminal** and run these, again with your own file name and IP address. The `chmod` line makes the key private to you, because SSH refuses to use a key other people could read.

```bash
mv ~/Downloads/ssh-key-2026-10-07.key ~/.ssh/oracle-n8n.key
chmod 600 ~/.ssh/oracle-n8n.key
ssh -i ~/.ssh/oracle-n8n.key ubuntu@203.0.113.10
```

The first time, SSH asks whether you trust the server. Type `yes` and press Enter. You are connected when the prompt changes to something like `ubuntu@n8n:~$`. Leave this window open for step 6.

## Step 4: Put the login screen in place first

Do this before n8n goes live, because the first person to open a new n8n instance becomes its owner. With the login screen already in place, that person can only be you.

In the Cloudflare dashboard, open **Zero Trust**, then **Access controls**, then **Applications**, and select **Add an application**, then **Self-hosted**.

**The first application protects the editor.**

1. Name it `n8n`.
2. Add a public hostname: your n8n subdomain (for example `n8n`) and your domain. Leave the path empty, so the whole address is covered.
3. Add a policy named `Me` with the action **Allow**, and an **Include** rule of **Emails** set to your own email address.
4. Save. Cloudflare decides how you log in from your Zero Trust settings. Accounts set up since June 2026 sign you in with your Cloudflare account, while older ones usually send a one-time code to your email; either works here, provided the email in the policy is the one you log in with. You can check which you have under **Zero Trust**, then **Integrations**, then **Identity providers**.

**The second application lets webhooks through.** Outside services, such as a form tool or a payment provider, cannot log in, so the paths n8n uses to receive webhooks have to stay open.

1. Add another **Self-hosted** application named `n8n webhooks`.
2. Add two public hostnames, both using your n8n address: one with the path `webhook/*` and one with the path `webhook-test/*`.
3. Add a policy with the action **Bypass** and an **Include** rule of **Everyone**.
4. Save.

Cloudflare applies the more specific path, so these two paths skip the login while everything else keeps it. Since anyone can reach a bypassed path, protect each webhook inside n8n as well: on the Webhook node, set **Authentication** to **Header Auth**, so a caller without the secret header is turned away.

## Step 5: Create the Cloudflare Tunnel

1. In the Cloudflare dashboard, go to **Networking**, then **Tunnels**, and select **Create a tunnel**.
2. Name it `n8n` and select **Create Tunnel**.
3. When asked for your environment, choose **Docker**. Cloudflare shows a command; do not run it. Copy only the long token at its end, which starts with `eyJ`. You will paste it in step 6.
4. Open the tunnel's **Routes** tab, select **Add route**, then **Published application**.
5. Enter your n8n subdomain and domain. For the service, enter `http://n8n:5678`, which is the name and port the n8n program uses inside Docker.
6. Save. Until step 6 is done, the address shows an error page, which is expected.

## Step 6: Install and start n8n on the server

Go back to the SSH window from step 3 and paste these commands one at a time, pressing Enter after each. The first installs Git, the second downloads this folder from GitHub, and the last two start the setup.

```bash
sudo apt-get update && sudo apt-get install -y git
git clone --depth 1 --branch claude/kind-pascal-myaulq https://github.com/TheEghosa/dev-resources.git
cd dev-resources/n8n-selfhost
bash setup.sh
```

If this folder has since been merged into the repository's `main` branch, use `--branch main` instead.

The script installs Docker and then asks three questions: your n8n address, your timezone (for example `Africa/Lagos` or `Europe/London`) and the tunnel token from step 5. The token stays invisible while you paste it, which is normal. The script then generates the encryption key, starts n8n and checks that the tunnel connected. The first run takes a few minutes, since it downloads both programs.

## Step 7: Create your n8n owner account and API key

1. Open your n8n address in a browser. Cloudflare's login screen appears first (your Cloudflare account, or an emailed code, depending on your settings from step 4), which proves the editor is protected.
2. n8n then asks you to create the owner account. Use a strong password and store it in a password manager.
3. In n8n, open **Settings**, then **n8n API**, and select **Create an API key**. Label it `Claude` and pick an expiry date (90 days is a sensible balance, because an expired key is harmless if it ever leaks). Copy the key, since n8n shows it only once.

Before moving on, check the webhook bypass from step 4 in a private browser window. Opening `https://your-n8n-address/webhook/test` should show a plain n8n "not registered" message rather than the Cloudflare login page. If you see the login page, the second application from step 4 needs another look.

## Step 8: Create a service token for Claude

Claude cannot fill in a login screen, so Cloudflare needs a separate key that lets it through without one.

1. In **Zero Trust**, go to **Access controls**, then **Service credentials**, then **Service Tokens**, and select **Create Service Token**.
2. Name it `claude-n8n` and choose a duration.
3. Copy both the **Client ID** and the **Client Secret**. Cloudflare shows the secret only once.
4. Go back to **Applications**, open the `n8n` application from step 4, and add a second policy named `Claude` with the action **Service Auth** and an **Include** rule of **Service Token** set to `claude-n8n`.

## Step 9: Hand the keys to the Claude environment

Never paste these into the chat, because chat messages are stored in the conversation history. Put them in the environment settings instead: open the environment menu in the Claude session's title bar and select **Edit**, then add these under **Network secrets** (or as environment variables, if that section is not offered).

| Name | Value |
|---|---|
| `N8N_BASE_URL` | Your full n8n address, such as `https://n8n.yourdomain.com` |
| `N8N_API_KEY` | The key from step 7 |
| `CF_ACCESS_CLIENT_ID` | The Client ID from step 8 |
| `CF_ACCESS_CLIENT_SECRET` | The Client Secret from step 8 |

In the same settings, under **Network access**, add your n8n address to **Allowed domains**, otherwise the session's network rules may block it. The steps are also at [code.claude.com/docs/en/cloud-environments](https://code.claude.com/docs/en/cloud-environments#network-access). Secrets load when a session starts, so open a new session afterwards and ask Claude to run `bash n8n-selfhost/check-connection.sh`. It reports either a working connection or which piece needs fixing.

## Looking after the server

Every command below runs in an SSH session, from inside the `dev-resources/n8n-selfhost` folder.

**Back up `.env` today.** Print it with `cat .env` and save the contents in your password manager. The encryption key inside it is what lets n8n read the logins you save in it; if the server is lost without that key, every saved login has to be entered again.

**Back up your workflows regularly.** This stops n8n briefly, copies its data into a dated file, and starts it again:

```bash
sudo docker compose stop n8n
sudo docker run --rm -v n8n_data:/data -v "$PWD":/backup alpine tar czf /backup/n8n-backup-$(date +%F).tar.gz -C /data .
sudo docker compose start n8n
```

Download that file to your own computer, because a backup that only lives on the server disappears with it. On a Mac or in PowerShell, run `scp -i <your key> ubuntu@<your IP>:dev-resources/n8n-selfhost/n8n-backup-*.tar.gz .` from your own machine.

**Update n8n on your schedule.** The version is fixed in `compose.yaml` (currently `2.42.4`), so nothing changes by surprise. To update, read the [n8n release notes](https://docs.n8n.io/release-notes/), take a backup, change the version number in `compose.yaml` with `nano compose.yaml`, then run:

```bash
sudo docker compose pull
sudo docker compose up -d
```

**See what is happening.** `sudo docker compose ps` shows whether both programs are running, and `sudo docker compose logs n8n --tail 50` shows n8n's recent messages. Swap `n8n` for `cloudflared` to see the tunnel's messages.

## When something goes wrong

| What you see | Most likely cause | What to do |
|---|---|---|
| Oracle says "out of capacity" | No free Ampere servers in that availability domain right now | Try another availability domain, or try again later |
| SSH says "UNPROTECTED PRIVATE KEY FILE" | The key file can be read by other users | Rerun the `icacls` or `chmod` line from step 3 |
| The browser shows a Cloudflare 502 or 1033 error | The tunnel or n8n is not running | Run `sudo docker compose ps`, then check the logs |
| The tunnel logs say "Provided Tunnel token is not valid" | The token was copied with extra text | Run `rm .env`, then `bash setup.sh` again and paste only the token |
| Webhooks from outside services get a login page | The webhook bypass application is missing or has the wrong paths | Recheck the second application in step 4 |
| n8n says it cannot decrypt credentials | The encryption key in `.env` changed | Restore the original `.env` from your backup |

## What this setup leaves out, on purpose

This is the smallest setup that is safe to rely on, which is why a few things are missing. n8n stores its data in its built-in SQLite database, which suits a single user; n8n recommends PostgreSQL for heavier production use, and adding it later is a contained change. The optional sandbox services that power n8n's built-in AI assistant code execution are also left out, since ordinary workflows, including Code nodes, run without them.
