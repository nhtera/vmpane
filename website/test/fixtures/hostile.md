<!-- SPDX-License-Identifier: Apache-2.0 -->

# Hostile fixture

Content from a docs pull request is untrusted. Everything below must render
as inert text or be dropped; nothing may run.

Expression: {process.env.HOME}

Template: {{base_url}}/users/{{id}}

Generic: Map<string, number> and <angle brackets>

<script>alert(1)</script>

<img src=x onerror=alert(1)>

<!-- a comment that must not reach the page -->

[javascript link](javascript:alert(1))

<div onclick="alert(1)">inline block</div>

```sh
curl {{base_url}}/health
echo done
```
