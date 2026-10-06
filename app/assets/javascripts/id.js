//= require @openstreetmap/id/dist/iD.js
//= require jquery.throttle-debounce

/* globals iD */

document.addEventListener("DOMContentLoaded", function () {
  const container = document.getElementById("id-container");

  if (typeof iD === "undefined" || !iD.utilDetect().support) {
    container.innerHTML = "This editor is supported " +
      "in Firefox, Chrome, Safari, Opera and Edge. " +
      "Please upgrade your browser or use JOSM to edit the map.";
    container.className = "unsupported";
  } else {
    // iD 默认在浏览器里直接去 jsDelivr 取 tagging schema（presets / fields /
    // 分类 / 默认列表 / tagging 语言包）。那几个值在 iD 的 fileMap 里是**绝对
    // URL**，而 iD 的 asset() 对 http(s) 开头的值直接原样返回、不查 asset map
    // （modules/core/file_fetcher.js），所以「只往 asset_map 里加条目」是不生效的。
    //
    // 这里先把 fileMap 里那几个键换成相对路径（data/xxx.min.json），asset() 才会
    // 走 assetPath("@openstreetmap/id/dist/") + assetMap 这条路 —— 也就是底图
    // imagery.min.json 一直在走的那条路 —— 最终落到 IdPresetsController，
    // 内容是 config/id_minecraft/ 里「iD 基础 schema + minecraft:* 预设」的合并产物。
    //
    // 覆盖表由 Rails 端给出（site/id.html.erb 的 data-id-schema-files，
    // 内容来自 IdMinecraftPresets.file_map）；产物没构建时它是空对象，行为不变。
    //
    // ⚠️ iD.fileFetcher 是 coreFileFetcher 的**单例对象**（iD.js 里
    // `export { _mainFileFetcher as fileFetcher }`），它**不是函数** ——
    // 千万别写成 iD.fileFetcher()。那会抛
    // `TypeError: iD.fileFetcher is not a function`，而这段代码在
    // DOMContentLoaded 回调里、iD.coreContext() 之前，一抛异常编辑器就再也不会
    // 初始化：打开 /id 只有一片空白 + 控制台一条报错。
    // （对比：iD.coreContext / iD.utilDetect 导出的是函数，所以它们要加括号。）
    const schemaFiles = JSON.parse(container.dataset.idSchemaFiles || "null") || {};
    const iDFileMap = iD.fileFetcher.fileMap();
    Object.keys(schemaFiles).forEach(function (key) {
      iDFileMap[key] = schemaFiles[key];
    });

    const idContext = iD.coreContext();
    idContext.connection().apiConnections([]);
    const url = location.protocol + "//" + location.host;
    idContext.preauth({
      url: url,
      apiUrl: url.replace("www.openstreetmap.org", "api.openstreetmap.org"),
      access_token: container.dataset.token
    });

    const id = idContext
      .embed(true)
      .assetPath("@openstreetmap/id/dist/")
      .assetMap(JSON.parse(container.dataset.assetMap))
      .locale(container.dataset.locale)
      .theme(container.dataset.theme)
      .containerNode(container)
      .init();

    if (parent === window) {
      // iD not opened in an iframe -> skip setting of parent  handlers
      return;
    }

    function postMessageToParent(type, data) {
      parent.postMessage({ type, data }, location.origin);
    }

    id.map().on("move.embed", window.Cowboy.throttle(250, function () {
      if (id.inIntro()) return;
      const zoom = ~~id.map().zoom(),
            center = id.map().center(),
            llz = { lon: center[0], lat: center[1], zoom: zoom };

      postMessageToParent("hashchange", llz);
    }));

    window.addEventListener("message", function (event) {
      if (event.source !== parent || event.origin !== location.origin) return;
      const msg = event.data;
      if (!msg || msg.type !== "hashchange") return;
      const data = msg.data;
      // 0ms timeout to avoid iframe JS context weirdness.
      // https://gist.github.com/jfirebaugh/5439412
      setTimeout(function () {
        id.map().centerZoom(
          [data.lon, data.lat],
          Math.max(data.zoom || 15, 13));
      }, 0);
    });

    new MutationObserver(() =>
      postMessageToParent("titlechange", document.title)
    ).observe(document.querySelector("title"), { childList: true, subtree: true, characterData: true });
  }
});
