# Animaciones R6 de Monster Eater

Fuentes originales `.rbxanim` en la raíz del proyecto: no se modifican. Los
modelos XML importables se generan en esta carpeta mediante
`tools/convert_rbxanim.py`.

| Animación | Modelo convertido | Claves | Duración | ID publicado |
| --- | --- | ---: | ---: | --- |
| AnimacionCaminar | `Walk_New_R6.rbxmx` | 9 | 1.333333 s | `104789365891956` |
| idle-doblesword-escudoyespada | `Idle_SwordAndShield_R6.rbxmx` | 108 | 4.458333 s | Pendiente de publicar |
| AT-CUBRIR SNS | `Cover_SwordAndShield_R6.rbxmx` | 5 | 0.333333 s | Pendiente de publicar |
| idle-GRANSWORD | `Idle_Greatsword_R6.rbxmx` | 7 | 4.458333 s | Pendiente de publicar |
| AT-DASH | `Dash_R6.rbxmx` | 6 | 1.25 s | Pendiente de publicar |

Las cinco fuentes usan secuencias R6 comprimidas con Zlib y JSON. El convertidor
retiene muestras de pose dispersas, marcas de tiempo, traslaciones y matrices de
rotación. Las validaciones locales confirmaron que las muestras y tiempos
coinciden con el XML generado.

El ID de la caminata nueva pertenece al mismo usuario propietario de la
experiencia. `ContentProvider:PreloadAsync` devolvió `Success` en Studio; esto
confirma que el asset se puede obtener, no que su reproducción en juego ya se
haya validado.

## Publicación

Importa cada secuencia en Animation Editor de Roblox Studio con un rig R6 y
publícala con el creador propietario de la experiencia. Registra el ID que
Studio devuelve en `src/shared/Config/SprintAnimationConfig.lua`. Los IDs en
blanco están desactivados hasta la publicación. No se reutilizaron IDs.

La caminata publicada anteriormente (`rbxassetid://85485981784931`) fue retirada
del controlador; su reemplazo no se activará hasta que se publique y configure
el nuevo ID. Sprint normal y Sprint con Sword conservan sus IDs actuales.

## Armas provisionales

`SwordAndShield_Prototype.rbxm` y `Greatsword_Prototype.rbxm` son copias de la
Tool `Sword.rbxm` para probar nombres de Tools y selección de Idle. Rojo las
construye como Tools llamadas `SwordAndShield_Prototype` y
`Greatsword_Prototype`; la configuración de Idle debe usar esos nombres exactos.
No son modelos finales y no añaden escudo ni geometría de Greatsword.
Reemplázalos cuando el modelador entregue ambos modelos específicos.

La cobertura está registrada como recurso exclusivo de Sword and Shield, sin
reproducirse: Monster Eater aún no implementa cobertura. El Dash existente
señala su aceptación mediante `MovementDashing`; el cliente selecciona esa
animación únicamente mientras el atributo está activo. Dash todavía no tiene
ID publicado. Su recurso dura 1.25 s, mientras que `MovementConfig.DashDuration`
es 0.25 s; hay que verificar el ajuste visual de duración/velocidad en juego
antes de activar la pista. Además, el controlador precarga tras recibir
`MovementDashing`; si la descarga en frío tarda más que la ventana de Dash, el
cambio del atributo puede invalidar la carga antes de reproducir. Conviene
precargar el asset al conectar el Animator antes de habilitar la pista.
