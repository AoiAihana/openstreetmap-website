// 在 Node 里直接跑 iD 的 add_member 算法，验证「往关系里加成员会不会丢掉未下载成员」。
//
// 代码逐字照抄自 @openstreetmap/id 2.40.0：
//   modules/osm/multipolygon.js  -> osmJoinWays
//   modules/actions/add_member.js -> addWayMember
// 只把依赖替换成最小实现（utilArrayGroupBy / utilObjectOmit / actionReverse /
// osmWay），不改动算法本身。运行：node test-add-member.mjs

// ---- iD util 的最小等价实现 ----------------------------------------------
function utilArrayGroupBy(collection, key) {
    return collection.reduce(function (groups, item) {
        var k = (typeof key === 'function') ? key(item) : item[key];
        (groups[k] = groups[k] || []).push(item);
        return groups;
    }, {});
}
function utilObjectOmit(obj, omitKeys) {
    var result = {};
    for (var k in obj) {
        if (omitKeys.indexOf(k) === -1) result[k] = obj[k];
    }
    return result;
}
// 成员是普通对象（不是 osmWay 实例），reverse() 会原样返回 item；
// actionReverse 只被塞进 sequences.actions，测试里不执行。
function actionReverse() { return function (g) { return g; }; }
class osmWay {}

// ---- 逐字照抄：modules/osm/multipolygon.js -------------------------------
function osmJoinWays(toJoin, graph) {
    function resolve(member) {
        return graph.childNodes(graph.entity(member.id));
    }
    function reverse(item) {
        var action = actionReverse(item.id, { reverseOneway: true });
        sequences.actions.push(action);
        return (item instanceof osmWay) ? action(graph).entity(item.id) : item;
    }
    toJoin = toJoin.filter(function (member) {
        return member.type === 'way' && graph.hasEntity(member.id);
    });
    var i;
    var joinAsMembers = true;
    for (i = 0; i < toJoin.length; i++) {
        if (toJoin[i] instanceof osmWay) { joinAsMembers = false; break; }
    }
    var sequences = [];
    sequences.actions = [];
    while (toJoin.length) {
        var item = toJoin.shift();
        var currWays = [item];
        var currNodes = resolve(item).slice();
        while (toJoin.length) {
            var start = currNodes[0];
            var end = currNodes[currNodes.length - 1];
            var fn = null;
            var nodes = null;
            for (i = 0; i < toJoin.length; i++) {
                item = toJoin[i];
                nodes = resolve(item);
                if (joinAsMembers && currWays.length === 1 && nodes[0] !== end && nodes[nodes.length - 1] !== end &&
                    (nodes[nodes.length - 1] === start || nodes[0] === start)) {
                    currWays[0] = reverse(currWays[0]);
                    currNodes.reverse();
                    start = currNodes[0];
                    end = currNodes[currNodes.length - 1];
                }
                if (nodes[0] === end) { fn = currNodes.push; nodes = nodes.slice(1); break; }
                else if (nodes[nodes.length - 1] === end) { fn = currNodes.push; nodes = nodes.slice(0, -1).reverse(); item = reverse(item); break; }
                else if (nodes[nodes.length - 1] === start) { fn = currNodes.unshift; nodes = nodes.slice(0, -1); break; }
                else if (nodes[0] === start) { fn = currNodes.unshift; nodes = nodes.slice(1).reverse(); item = reverse(item); break; }
                else { fn = null; nodes = null; }
            }
            if (!nodes) break;
            fn.apply(currWays, [item]);
            fn.apply(currNodes, nodes);
            toJoin.splice(i, 1);
        }
        currWays.nodes = currNodes;
        sequences.push(currWays);
    }
    return sequences;
}

// ---- 逐字照抄：modules/actions/add_member.js 的 addWayMember -------------
function makeAddWayMember() {
    return function addWayMember(relation, graph, member) {
        var groups, item, i, j, k;

        var PTv2members = [];
        var members = [];
        for (i = 0; i < relation.members.length; i++) {
            var m = relation.members[i];
            if (/stop|platform/.test(m.role)) { PTv2members.push(m); }
            else { members.push(m); }
        }
        relation = relation.update({ members: members });

        groups = utilArrayGroupBy(relation.members, 'type');
        groups.way = groups.way || [];
        groups.way.push(member);

        members = withIndex(groups.way);
        var joined = osmJoinWays(members, graph);

        for (i = 0; i < joined.length; i++) {
            var segment = joined[i];
            var nodes = segment.nodes.slice();
            var startIndex = segment[0].index;
            for (j = 0; j < members.length; j++) {
                if (members[j].index === startIndex) break;
            }
            for (k = 0; k < segment.length; k++) {
                item = segment[k];
                var way = graph.entity(item.id);
                if (k > 0) {
                    if (j + k >= members.length || item.index !== members[j + k].index) {
                        moveMember(members, item.index, j + k);
                    }
                }
                nodes.splice(0, way.nodes.length - 1);
            }
        }

        var wayMembers = [];
        for (i = 0; i < members.length; i++) {
            item = members[i];
            if (item.index === -1) continue;
            wayMembers.push(utilObjectOmit(item, ['index']));
        }

        var newMembers = PTv2members.concat((groups.node || []), wayMembers, (groups.relation || []));
        return relation.update({ members: newMembers });

        function moveMember(arr, findIndex, toIndex) {
            var i;
            for (i = 0; i < arr.length; i++) {
                if (arr[i].index === findIndex) break;
            }
            var item = Object.assign({}, arr[i]);
            arr[i].index = -1;
            delete item.index;
            arr.splice(toIndex, 0, item);
        }
        function withIndex(arr) {
            var result = new Array(arr.length);
            for (var i = 0; i < arr.length; i++) {
                result[i] = Object.assign({}, arr[i]);
                result[i].index = i;
            }
            return result;
        }
    };
}

// ---- 搭一个最小 graph ----------------------------------------------------
function makeGraph(loaded) {           // loaded: {id: [nodeIds]}
    return {
        hasEntity: function (id) { return Object.prototype.hasOwnProperty.call(loaded, id); },
        entity: function (id) { return { id: id, type: 'way', nodes: loaded[id] }; },
        childNodes: function (e) { return (loaded[e.id] || []).slice(); }
    };
}
function makeRelation(members) {
    var rel = { id: 'r117', type: 'relation', members: members };
    rel.update = function (attrs) { return Object.assign({}, rel, attrs); };
    return rel;
}
function fmt(ms) { return ms.map(function (m) { return m.id + (m.role ? '(' + m.role + ')' : ''); }).join(', '); }

const addWayMember = makeAddWayMember();

function run(label, memberList, loaded, newMember) {
    // loaded 里含 w3（新加的），w2 故意不加载（模拟「未下载的成员」）
    const graph = makeGraph(loaded);
    const rel = makeRelation(memberList.map(function (id) { return { id: id, type: 'way', role: '' }; }));
    const before = rel.members.slice();
    const after = addWayMember(rel, graph, newMember).members;
    const lost = before.filter(function (m) { return !after.some(function (a) { return a.id === m.id; }); });
    console.log('  ' + label);
    console.log('    加载进 graph 的 way : ' + Object.keys(loaded).join(', '));
    console.log('    关系成员 before     : ' + fmt(before));
    console.log('    关系成员 after      : ' + fmt(after));
    console.log('    >> 被丢弃的成员     : ' + (lost.length ? fmt(lost) + '   ★★★ 丢数据' : '无'));
    console.log('');
    return lost;
}

console.log('=== 复现用户场景：关系里有一个「未下载」成员，再添加一个成员 ===');
console.log('');
let any = 0;
any += run('A) w1、w2 都在 graph 里（都下载了）',
    ['w1', 'w2'], { w1: ['n1', 'n2'], w2: ['n2', 'n3'], w3: ['n3', 'n4'] },
    { id: 'w3', type: 'way', role: '' }).length;

any += run('B) w2 未下载（不在 graph 里）—— 用户说的那种情况',
    ['w1', 'w2'], { w1: ['n1', 'n2'], w3: ['n2', 'n3'] },
    { id: 'w3', type: 'way', role: '' }).length;

any += run('C) w1、w2、w3 都未下载，只加一条新的',
    ['w1', 'w2'], { w4: ['n9', 'n10'] },
    { id: 'w4', type: 'way', role: '' }).length;

console.log(any ? '结论：未下载的成员确实会被丢弃（' + any + ' 处）' : '结论：未复现丢弃');
