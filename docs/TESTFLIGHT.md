# Subir Noria a TestFlight (macOS)

Esta guía usa el esquema **Noria** (el que Xcode muestra por defecto; bundle ID
`com.juanmarcos.noria`, equipo `62395T6WLG`), que funciona dentro del App
Sandbox como exige la Mac App Store. El esquema **Noria Direct**
(`com.juanmarcos.noria.direct`) es la edición de distribución directa y **no** se
puede subir a App Store Connect.

## 1. Una sola vez: registrar la app

1. **App ID** — <https://developer.apple.com/account/resources/identifiers/list>
   → **+** → *App IDs* → *App* → plataforma **macOS**, *Bundle ID explícito*
   `com.juanmarcos.noria`, descripción "Noria". No hace falta activar capacidades
   extra. (Si lo omites, la firma automática de Xcode lo crea al archivar.)
2. **App en App Store Connect** — <https://appstoreconnect.apple.com> → *Apps* →
   **+** → *Nueva app*:
   - Plataforma: **macOS**
   - Nombre: `Noria` (si está ocupado en la tienda, por ejemplo `Noria – Mac Cleaner`)
   - Idioma principal: Español (o Inglés)
   - Bundle ID: `com.juanmarcos.noria`
   - SKU: `noria-mac`
   - Acceso de usuario: Acceso total

## 2. Cada versión: archivar y subir

1. Abre `Noria.xcodeproj` en Xcode.
2. Sube el número de build: en `project.yml`, `CURRENT_PROJECT_VERSION` (1, 2, 3…)
   y ejecuta `xcodegen generate`; o directamente en Xcode → target *Noria* →
   *General* → *Build*. **Cada subida necesita un número nuevo.**
   La versión visible es `MARKETING_VERSION` (ahora 0.1.0).
3. Arriba, comprueba que el esquema sea **Noria** (no "Noria Direct") y elige el
   destino **Any Mac (Apple Silicon, Intel)**.
4. Menú **Product → Archive**. Al terminar se abre el *Organizer*.
5. Selecciona el archivo → **Distribute App** → **App Store Connect** → **Upload**
   (o *TestFlight & App Store*). Deja *Automatically manage signing*: Xcode crea
   los certificados *Apple Distribution* y *Mac Installer Distribution* y el
   perfil de aprovisionamiento.
6. Xcode valida y sube el build. Si muestra errores, cópialos y pásamelos.

## 3. TestFlight

1. Espera el correo "The build has completed processing" (10–30 min). El build
   aparece en App Store Connect → *Noria* → pestaña **TestFlight**.
2. *Cumplimiento de exportación*: ya está resuelto en el `Info.plist`
   (`ITSAppUsesNonExemptEncryption = NO`), no debería preguntarte.
3. **Pruebas internas** (sin revisión de Apple, disponible al instante):
   *Internal Testing* → **+** → crea un grupo (p. ej. "Equipo") → añade tu
   usuario (debe tener un rol en App Store Connect) → añade el build.
4. **Pruebas externas** (opcional, hasta 10 000 personas): *External Testing* →
   crea un grupo → añade el build → completa *Test Information* (descripción,
   correo de contacto, qué probar) → envía a **Beta App Review** (suele tardar
   1–2 días). Después puedes invitar por correo o con un enlace público.

## 4. Instalar en tu Mac

1. Instala **TestFlight** desde la Mac App Store.
2. Inicia sesión con el Apple ID invitado y acepta la invitación.
3. Pulsa **Instalar** junto a Noria.
4. Al pulsar **Analizar mi Mac** por primera vez, macOS muestra un panel abierto
   en tu carpeta de inicio: pulsa **Permitir acceso** sin seleccionar nada más.
   Noria recuerda el permiso; puedes revocarlo en *Configuración → Acceso a
   carpetas*.

## Diferencias de la edición App Store

| | Directa (`Noria Direct`) | App Store (`Noria`) |
|---|---|---|
| Sandbox | No | Sí (obligatorio) |
| Acceso a archivos | Normal (con avisos de privacidad de macOS) | Solo la carpeta de inicio que el usuario permite |
| Archivos temporales | Sí | No disponible (el sandbox redirige la carpeta temporal) |
| Papelera (tamaño) | Con Acceso total al disco | Con Acceso total al disco |
| Mover a la Papelera / eliminar | Sí | Sí, dentro de la carpeta permitida |

## Revisión de Apple

Las pruebas **internas** no pasan revisión. Las **externas** y la publicación en
la tienda sí: Apple revisa con especial cuidado las apps de limpieza (pide que no
exageren problemas ni prometan "acelerar" el Mac sin fundamento). Noria ya sigue
ese criterio — muestra datos reales, explica cada elemento y nunca borra sin
confirmación —, pero conviene describirla así en la ficha.
