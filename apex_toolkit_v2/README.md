# KMLeon Toolkit 2 (preview)

A native-APEX rework of the toolkit application in [`apex_toolkit/`](../apex_toolkit/).
It is installed as a **separate application (id 1200, alias `kmleon2`)** so that both
variants can run side by side; the original toolkit (app 1100) is unchanged.

Design rules of this rework:

* everything that APEX does natively runs natively: modal dialog pages, Cards, Map
  regions with feature links, declarative validations, page processes, success
  messages, confirmations, the application error handler
  (`pck_kmleon_tools.apex_error_handler`);
* custom code is kept to a minimum: one static file
  (`shared-components/static-files/kmleon-draw.js`, ~70 lines) lets the user click a
  Point / LineString / Polygon into the Map region of the Feature dialog - the
  preview, validation and saving are native APEX;
* one language (English), consistent page titles, side navigation.

Pages: 1 Dashboard · 2 Job (modal) · 3 New job · 5 Logs · 7 Settings · 8 Async
playground · 9 Download · 10 Query helper · 11 Editor (admins and access-key
links) · 12 Feature (modal) · 110 My maps (public) · 9999 Sign in.

Install / update (same as the original toolkit):

```text
sql kmleon/<password>@//host:1521/FREEPDB1
SQL> @apex_toolkit_v2/setup.sql
SQL> apex import -input apex_toolkit_v2
```
