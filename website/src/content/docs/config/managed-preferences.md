---
title: Managed Preferences
description: Organization policy for OmniShell network hosts, native programs and built-in services.
sidebar:
  order: 3
---

**Unreleased: available when building from `main`.** These OmniShell policy controls are not included in v0.7.6.

Organizations can manage OmniShell through forced preferences in **`com.barut.OmniWM`**. The separate Dev app reads **`com.barut.OmniWM.dev`**. Only forced values count; ordinary `defaults write` values are ignored. The policy covers the Luau HTTP API, native provider launches and the built-in Weather and Lyrics services, not update checks, embedded terminals or browser `openURL` actions.

## Keys and invalid values

| Key | Type | Default when absent | Effect | Invalid forced value |
|---|---|---|---|---|
| `ShellNetworkAllowedHosts` | string array | `[]` | Preapprove declared widget hosts | Empty preapproval list |
| `ShellNetworkBlockedHosts` | string array | `[]` | Block matching hosts | Block every shell host |
| `ShellNetworkOnlyAllowedHosts` | Boolean | `false` | Block hosts outside the managed allowed list | `true` |
| `ShellProvidersAllowed` | Boolean | `true` | `false` stops and prevents native providers | `false` |
| `ShellBlockedServices` | string array | `[]` | Force `weather` and/or `lyrics` off | Block both services |

Every invalid forced value also shows a policy error in **Settings > Network & Permissions**. Use real Boolean values, not strings or integers. Unknown service names invalidate the whole services list. An invalid allowed-host list removes preapproval; it does not alone override a user Allow unless allowlist-only or another block applies.

Use exact host names or IP literals, without schemes, ports or paths. Case and trailing dots are normalized; a host covers any port, without wildcards or subdomain expansion. Managed Allow cannot add a missing declaration or permit non-loopback plain HTTP.

## Precedence and refresh

Organization blocks and allowlist-only exclusions win. User Deny wins over managed preapproval. Otherwise managed preapproval or user Allow permits a declared widget host. Native programs still need executable trust even when all their hosts are preapproved.

Host rules also cover the built-ins: Weather requires both `api.open-meteo.com` and `geocoding-api.open-meteo.com`; Lyrics requires `lrclib.net`. In allowlist-only mode, include every host a service needs. A host block or service block turns the whole service off and locks its switch.

OmniWM reads policy at launch, on settings reload and whenever Settings opens. There is no polling for profile changes. After a refresh, the Settings page reflects the effective policy, affected transfers are cancelled and blocked native providers stop. Bytes already sent cannot be recalled. These controls are not a sandbox or a firewall for trusted native programs.

## Example profile

[Download the example `.mobileconfig`](/examples/omnishell/managed-preferences.mobileconfig). It preapproves `api.github.com` and the Weather hosts (used by Weather if you turn on allowlist-only), blocks `blocked.example.com`, disables native providers and turns Lyrics off. Other declared widget hosts still require consent because allowlist-only is `false`.

The file uses Apple’s [managed-preferences payload](https://developer.apple.com/documentation/devicemanagement/managedpreferences), placing the five keys in `PayloadContent["com.barut.OmniWM"].Forced[0].mcx_preference_settings`. Adapt the policy and the example payload identifiers/UUIDs for your organization, then deploy it with your device-management service. To target OmniWM Dev, use `com.barut.OmniWM.dev` as the preference domain instead.

User choices remain in [settings.toml](/config/settings-reference/#shellpermissions). Organization policy is separate and takes precedence as described above.
