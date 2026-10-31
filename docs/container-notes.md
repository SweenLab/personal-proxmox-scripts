# Automatic centered Proxmox notes

The Debian LXC wizard automatically adds this generic block when creating a new container, saves it again after guest package setup, and verifies the saved description through the Proxmox API before reporting completion. It contains only the compact banner and repository links. Existing containers are left unchanged; to update one manually, open Summary → Edit notes and replace its note with the block below.

```html
<!-- Created by Sweenlab wizard 0.1.21 -->
<table width="100%" height="280">
<thead><tr><td align="center" valign="middle">
<img src="https://raw.githubusercontent.com/SweenLab/sweenlab-scripts/431677614bb80d7795f9e37ac7791b4a56f7900b/assets/branding/sweenlab-scripts-notes.png" alt="SWEENLAB SCRIPTS" width="280" height="112">
<br><br>
<a href="https://github.com/SweenLab/sweenlab-scripts">GitHub</a> · <a href="https://github.com/SweenLab/sweenlab-scripts/blob/main/docs/proxmox-debian-lxc-create.md">Guide</a> · <a href="https://github.com/SweenLab/sweenlab-scripts/releases">Releases</a>
</td></tr></thead>
</table>
```

The table uses a 280-pixel-high layout area with horizontal and vertical middle alignment. The image is physically 280 × 112 pixels. This gives a centered block suited to the standard Summary panel without application names or container-specific details. The wizard version is retained in a hidden comment.

This is fixed-height centering, not responsive centering against every possible Notes panel height. Proxmox sanitizes custom inline styles, so the note uses supported height/width/align/valign attributes rather than CSS or JavaScript. You can adjust the table height manually for a differently sized panel. No Proxmox UI files are changed.

References: [Notes HTML allowlist](https://github.com/proxmox/proxmox-widget-toolkit/blob/master/src/Parser.js), [Summary panel layout](https://github.com/proxmox/pve-manager/blob/master/www/manager6/panel/GuestSummary.js).

The [full banner and crest](../assets/branding/) remain available. Local workflow tests cover the complete multiline description, recovery when creation drops the notes, and failures or mismatches during the final save/readback. Live provisioning and panel rendering of this release still need confirmation.
