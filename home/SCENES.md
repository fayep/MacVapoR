# Home scenes

While no game holds the headset, MacVapoR shows a home scene: somewhere to stand, with your
hands or controllers, and a ball on a table to throw. The scene is a folder, so it can be swapped
for another by choosing it in MacVapoR or by dropping in a folder of your own.

Two come with MacVapoR:

- **Vaporwave**: a neon grid down to a silver beach, palms, and a striped sun setting into the sea.
- **Studio**: a quiet grey floor under a pale sky.

## Where scenes live

| Folder | What's there |
| --- | --- |
| `~/Library/Application Support/MacVapoR/runtime/scenes/` | The scenes that come with MacVapoR. Reinstalling replaces them, so don't edit them here. |
| `~/Library/Application Support/MacVapoR/scenes/` | Your own scenes. A scene here with the same folder name as a built-in one takes its place. |
| `~/Library/Application Support/MacVapoR/home.json` | Which scene is shown: `{"scene": "studio"}`, by folder name. MacVapoR's Home Scene picker writes it. |

The home scene notices within a second when you choose another scene or change any file in the
one showing, and loads it again: edit and save, and look. If the change doesn't load (a shader
that doesn't compile, say), the scene you had stays up, and the reason is in
`~/Library/Logs/vapord.log`.

## What's in a scene

```
my-scene/
  scene.json        what the scene is and its colours
  backdrop.metal    the world around you
  *.png             pictures it stands up in the world, and the ball's and table's surfaces
```

The easiest start is a copy of one that comes with MacVapoR:

```sh
cd ~/Library/Application\ Support/MacVapoR
mkdir -p scenes && cp -R runtime/scenes/studio scenes/my-scene
```

Then change `"name"` in `scenes/my-scene/scene.json`, and choose it in MacVapoR.

### scene.json

Every key is optional except `name`. Colours are sRGB, each 0 to 1. Distances are metres, with
the floor at y = 0, you standing at the origin, and ahead along -z.

```json
{
  "name": "My Scene",
  "about": "One line for the picker.",
  "shader": "backdrop.metal",
  "pictures": [
    {"image": "sign.png", "centre": [0, 4, -12], "size": [8, 3]},
    {"image": "tree.png", "centre": [6, 3, -10], "size": [3, 6], "flip": true}
  ],
  "ball": "ball.png",
  "table": [0.36, 0.37, 0.40],
  "light": {"from": [0.3, 1, 0.4], "colour": [1, 0.98, 0.95], "shade": 0.45},
  "rim": {"colour": [1, 1, 1], "strength": 0.2},
  "ambient": {"colour": [0.55, 0.6, 0.7], "strength": 0.03},
  "hands": {"bones": [0.25, 0.55, 1.0], "palm": [0.45, 0.40, 0.95], "tips": [1, 1, 1]},
  "controls": {"touched": [0.30, 0.55, 0.95], "pressed": [1.0, 0.58, 0.25]}
}
```

| Key | Meaning |
| --- | --- |
| `pictures` | Up to 16 upright, flat pictures facing you (they face +z), drawn over the backdrop furthest first, so list the furthest first. `centre` is the picture's middle; `size` its width and height; `flip` mirrors it. Up to 8 different images. PNGs with transparency are fine: the backdrop shows through. A picture behind the backdrop's ground (further than where the floor meets the horizon, say) is hidden by it. |
| `ball`, `table` | A picture to wrap round each (the ball's runs once round its equator, top to bottom; each face of the table shows the whole picture), or a colour. |
| `light` | The direction light comes from (`from`), its colour, and `shade`: how lit the side away from it is, 0 to 1. Lights the ball, the table and the controllers. |
| `rim` | A glow round the edges of the ball, table and controllers. |
| `ambient` | A colour added to all of them. |
| `hands` | Bare hands are drawn as glowing lines: `bones` along the fingers, `palm` across the back of the hand, `tips` the dots on the fingertips. |
| `controls` | On the controllers, a button, stick or trigger glows `touched` when your finger is on it, and `pressed` when it's pressed. |

### backdrop.metal

The backdrop is a Metal function run for each pixel of each eye. It's given the eye's position
and the direction it's looking through that pixel, and returns the colour seen there:

```metal
float3 backdrop(float3 o, float3 d, constant Eye &eye, thread float &depth) {
    if (d.y >= 0) return lin(float3(0.4, 0.5, 0.7));   // sky
    depth = -o.y / d.y;                                 // how far to the floor
    float3 p = o + d * depth;                           // where on the floor
    return lin(float3(0.3)) * (0.8 + 0.2 * step(0.5, fract(p.x) + fract(p.z) - 0.5));
}
```

- `o` is the eye's position and `d` the direction, a unit vector, in the same metres as scene.json.
- The colour is linear, not sRGB: `lin(srgb)` converts.
- Set `depth` to how far along `d` the surface you drew is. Leave it alone (it starts at infinity)
  for sky. Pictures further than `depth` are hidden behind what you drew.
- `eye.time.x` is seconds since the scene started, for anything that moves. Keep the floor still:
  a moving floor makes people queasy.
- `eye.ball` is the ball's centre (`xyz`) and radius (`w`), for drawing its shadow. See either
  built-in scene's `backdrop.metal` for one.
- `hash(float2)` gives a pseudo-random number from 0 to 1, for stars, noise and the like.

Everything else is ordinary Metal: write helper functions and constants above `backdrop` as you
like. The definitions `backdrop.metal` is compiled after are in
[`prelude.metal`](prelude.metal). The shader runs twice per frame at the headset's full
resolution, so keep it cheap: a few dozen operations a pixel, no long loops.

### Seeing it without the headset

`vapord --preview` draws a scene into a PNG as you'd see it standing at the origin:

```sh
V=~/Library/Application\ Support/MacVapoR/runtime/vapord
"$V" --preview ~/Library/Application\ Support/MacVapoR/scenes/my-scene /tmp/my-scene.png
"$V" --preview ~/Library/Application\ Support/MacVapoR/scenes/my-scene /tmp/table.png -45 -40   # turned right, looking down at the table
open /tmp/my-scene.png
```

The two numbers are how far to turn left and to look up, in degrees. If the scene doesn't load,
`--preview` says why.

## What a scene can't change

The table and ball's place and size, the hands and controllers, and how you pick up and throw the
ball are the same in every scene. A scene draws what's around them.
