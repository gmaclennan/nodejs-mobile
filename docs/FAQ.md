# Frequently Asked Questions

- [Can I use npm node-modules with nodejs-mobile?](#can-i-use-npm-node-modules-with-nodejs-mobile)
- [Are all Node.js APIs supported on mobile?](#are-all-nodejs-apis-supported-on-mobile)
- [Does `fetch()` work? What about WebAssembly?](#does-fetch-work-what-about-webassembly)
- [Does HTTPS trust the device's certificates?](#does-https-trust-the-devices-certificates)
- [Trying to write a file results in an error. What's going on?](#trying-to-write-a-file-results-in-an-error-whats-going-on)
- [Are Node.js native modules supported?](#are-nodejs-native-modules-supported)
- [How can I improve Node.js load times?](#how-can-i-improve-nodejs-load-times)
- [Can I run two or more Node.js instances?](#can-i-run-two-or-more-nodejs-instances)
- [Can I run Node.js code in a WebView?](#can-i-run-nodejs-code-in-a-webview)
- [Can you support a plugin for the X mobile framework?](#can-you-support-a-plugin-for-the-x-mobile-framework)

## Can I use npm node-modules with nodejs-mobile?

npm modules can be used with nodejs-mobile. They need to be installed at development time in the application source folder that contains the Node.js project files. There are samples that show how to use npm modules for [Android](https://github.com/janeasystems/nodejs-mobile-samples/tree/master/android/native-gradle-node-folder) and [iOS](https://github.com/janeasystems/nodejs-mobile-samples/tree/master/ios/native-xcode-node-folder) when using the native library directly. There are instructions in the [nodejs-mobile-cordova](https://github.com/janeasystems/nodejs-mobile-cordova#node-modules) and [nodejs-mobile-react-native](https://github.com/janeasystems/nodejs-mobile-react-native#node-modules) plugins README on how to use them.

## Are all Node.js APIs supported on mobile?

Not every API is supported on mobile, the main reason for this being that the mobile operating systems won't allow applications to call certain APIs that are expected to be available on other operating systems. Examples:

- `child_process.spawn()`, `child_process.fork()` and other APIs that create new processes will run into permission issues
- `process.exit()` is not allowed by the Apple App Store guildelines
- `os.cpus()` returns unreliable or no data on mobile:
  - **iOS**: CPU speed values are always 0.
  - **Android 8.0+**: the call returns `undefined` (the OS no longer exposes per-core frequency to apps).
  - **Android < 8.0**: values can be inconsistent — some devices power cores on and off as an energy-saving strategy, so a core that is off at the moment of the call reports zero.
- `os.availableParallelism()`

A few other general JavaScript APIs are also unsupported due to Node.js Mobile not including full internationalization support:

- RegExp Unicode Property Names, for example `/\p{Letter}+/u`

WebAssembly is a special case on iOS — see
[the next question](#does-fetch-work-what-about-webassembly).

## Does `fetch()` work? What about WebAssembly?

`fetch()` works out of the box on both platforms. Applications do not need a
shim, a polyfill package, or a patched `undici`.

On **Android** nothing is unusual: V8 has its JIT and its own WebAssembly
implementation.

On **iOS** it takes some work, because Apple does not allow apps to generate
machine code at runtime. The iOS library therefore runs V8 **jitless**, and a
jitless V8 has *no* `WebAssembly` global at all. That matters well beyond
`WebAssembly` itself: `fetch()` is implemented by undici, and undici parses
HTTP with a WebAssembly build of llhttp. Without it, the first `fetch()` fails
with `WebAssembly is not defined`, and so does anything else undici backs —
`Response`, `Request`, `Headers`, `FormData`, `WebSocket`, `EventSource`.

The library ships a pure-JS WebAssembly implementation
([polywasm](https://github.com/evanw/polywasm), MIT, vendored in
[`deps/polywasm`](../mobile-src/deps/polywasm/README.md) — that README records
its provenance and how it is updated) and installs it as
`globalThis.WebAssembly` at startup **only when the engine has none** — so
Android and the host build keep V8's implementation untouched, and iOS gets a
working `fetch()`. It compiles each wasm function to JavaScript with
`new Function()`, which jitless V8 allows (that restriction is on machine code,
not on parsing source). The polyfill is loaded lazily: an app that never
touches WebAssembly never compiles it.

Worth knowing:

- **It is much slower than a real wasm engine.** Fine for llhttp-sized parsing
  work; do not expect native speed from a heavy wasm workload on iOS.
- **The supported subset is the wasm MVP plus some post-MVP proposals.** No
  SIMD, threads/atomics, exception handling, or GC. A module using those
  throws when the offending function is first called.
- **The namespace itself is not quite complete.** polywasm provides `Module`,
  `Instance`, `Memory`, `Table`, `Global`, `CompileError` and the
  `compile`/`instantiate`/`validate` functions. `LinkError` and `RuntimeError`
  are supplied on install, because they are part of the JS-API that node's own
  internals construct (`internal/modules/esm/translators.js`) and that
  `--frozen-intrinsics` reads the prototypes of at startup. `WebAssembly.Tag`
  and `WebAssembly.Exception` are simply absent — code that feature-detects
  them sees `undefined` rather than a thrown error, which is consistent with
  exception handling being unsupported above.
- **`UNDICI_NO_WASM_SIMD` is set to `1`** when the polyfill is installed.
  undici otherwise picks a SIMD build of llhttp, which polywasm compiles
  happily and then trips over on the first request (`Unsupported instruction:
  0xFD`), past undici's own fallback. Set the variable yourself and your value
  is left alone.
- **To use a different implementation**, assign to the global before anything
  touches it (`globalThis.WebAssembly = myImpl`) — the property is a normal
  writable global, exactly as V8's own is.

## Does HTTPS trust the device's certificates?

TLS trust comes from the **bundled** Mozilla root store compiled into the
library, so `https`, `fetch()` and `tls` work out of the box against
publicly-trusted endpoints on both platforms.

What does *not* work on iOS is reading the operating system's trust store:
iOS has no API to enumerate the system's trust anchors (apps may only ask the
system to evaluate a specific chain), so `tls.getCACertificates('system')`
returns an empty list and `--use-system-ca` adds nothing — verified on a real
device. In practice that means a root the *device* trusts but node's bundle
doesn't — an enterprise/MDM-installed CA, a TLS-intercepting corporate proxy,
a user-installed profile — is invisible to node on iOS. If your app must trust
such a CA, supply it explicitly: set `NODE_EXTRA_CA_CERTS` in the environment
before starting the runtime, or pass the certificate via the `ca` option of
the connection. Android is no better off through a different mechanism: the
non-Apple reader looks in OpenSSL's standard certificate locations, which an
app sandbox does not populate — so on both platforms, treat the bundled roots
as the trust base and add private CAs explicitly.

## Trying to write a file results in an error. What's going on?

Mobile platforms are different than the usual desktop platforms in that they require applications to write in specific sandboxed paths and don't have permissions to write elsewhere. You should pass an appropriate writable path for your use case to the Node.js runtime and write there. An API call to return the path most regularly used for data in each platform has been added to the [nodejs-mobile-cordova](https://github.com/janeasystems/nodejs-mobile-cordova#cordovaappdatadir) and [nodejs-mobile-react-native](https://github.com/janeasystems/nodejs-mobile-react-native#rn_bridgeappdatadir) plugins.

## Are Node.js native modules supported?

Node native modules, which contain native code, are able to run on nodejs-mobile, as long as they can be cross-compiled for the target platform / CPU. The cross-compiling feature is integrated into the plugins and instructions can be found in the [nodejs-mobile-cordova](https://github.com/janeasystems/nodejs-mobile-cordova#native-modules) or in the [nodejs-mobile-react-native](https://github.com/janeasystems/nodejs-mobile-react-native#native-modules) README, but only Linux and MacOS development machines are currently supported. Modules that contain custom build steps and platform specific code may need workarounds/changes to get them to work. We've created a github repository so that the workarounds/changes can be discussed and shared: https://github.com/janeasystems/nodejs-mobile-module-compat

## How can I improve Node.js load times?

Applications that contain a large number of files in the Node.js project can have their load times decreased by reducing the number of files. While installing npm modules, these can be installed with the `--production` flag, so that modules that are used for development only are not included in your project, e.g.: `npm install --production <module_name>`. Using tools that merge all nodejs project files into a bundle, such as [`noderify`](https://www.npmjs.com/package/noderify) or [`esbuild`](https://esbuild.github.io/) and using the bundle instead has been observed to improve load times in most situations.

## Can I run two or more Node.js instances?

No. The runtime expects to be run as a single instance in the process. In practice this should not preclude any usage scenarios, given node's asynchronous nature. Multiple sub-tasks can be executed by simply loading all the corresponding modules with `require` from a main script.

## Can I run Node.js code in a WebView?

No. Node.js uses a libuv event loop at its core, which is different than the event loop in the WebView. Having the node runtime run in its own thread also prevents Node.js tasks for interfering with the UI, which might cause responsiveness issues.
The supported usage scenario is that nodejs-mobile runs in a background thread and the UI (in this case a WebView) must use a communication mechanism to send/receive data from Node.js.
This technique is used in the `nodejs-mobile-cordova` plugin, where Cordova uses a dedicated thread to run Node.js alongside the WebView.

## Can you support a plugin for the X mobile framework?

We are currently focused on supporting cordova and react-native plugins only, but we are open to community contributions for other frameworks.
If you are interested in a particular framework, please see if [an issue](https://github.com/janeasystems/nodejs-mobile/issues/) for it has already been opened, and let us know about your interest in there. Otherwise, feel free to open a new issue.

