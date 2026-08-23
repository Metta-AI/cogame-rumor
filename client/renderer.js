// Rumor shared renderer + drivers.
//
// One canvas scene — the social graph as the stage: ten cogs on a circle,
// chalk edges between neighbours, a tinted coin on each node showing that
// cog's private clue, a belief meter shading red (option A) or blue
// (option B), and message pulses running along the edges every round. Under
// the graph a belief-tide strip charts all ten beliefs round by round: you
// watch a lie propagate. At the ballot the coins flip to sealed envelopes;
// at the tally they open, the saboteurs take a mask badge, and the truth is
// stamped across the middle.
//
// The broadcast chrome around it — topband, clock, statuschip, LOG toggle,
// scorebug, round-grouped feed, scrubber with per-event beats, transport
// bar, endscreen, name mapping — is cogame-bullwhip's, kept.
//
// Fed by three drivers: live /global websocket, live /player websocket,
// and replay (from the game's /replay websocket or the static wasm
// bundle). All state derivation happens server-side / wasm-side; this file
// only draws state objects:
//   {question,optionA,optionB,topology,edgeCount,edges[[a,b]…],
//    seats:[{name,seat,degree,neighbours[],clue,claim,confidence,belief,
//            message,role,vote|null,voteReason,notes,score,pending,
//            scripted} ×10 by SEAT],
//    round,rounds,roundsPlayed,phase:"talk|ballot|tally|done",
//    pulses:[{from,to,claim,confidence}], beliefs:[10 series],
//    votes:[10|null], sealed, truth, verdict, accuracy, honestCorrect,
//    saboteurCount, gameDone, reason}
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Ten
  // seats, ten colours: a seat keeps its colour and its position on the
  // circle for the whole episode.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange",
    "teal", "rose", "lime", "sand"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a",
    teal: "#2fa39b",
    rose: "#d4638f",
    lime: "#8cbf3f",
    sand: "#c2a06a"
  };
  var PAPER = "#f2e8d8";
  var PAPER_DIM = "#b8ac98";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var CHALK = "rgba(242, 232, 216, 0.30)";
  var SIDE_A = "#e0523a";        // option A reads red
  var SIDE_B = "#3f7cc4";        // option B reads blue
  var STRIP = "rgba(242, 232, 216, 0.06)";
  var SEATS = 10;
  // Timing of the round transition: pulses run the edges, bubbles pop.
  var SLIDE_MS = 700;
  var SLIP_MS = 900;
  var BUBBLE_HOLD_MS = 4200;
  // Under this canvas width the stage drops the speech bubbles and shortens
  // the name plates; the coins, meters, edges and pulses stay full size.
  var COMPACT_W = 560;

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = COLORS.map(function (color) {
      return "soldier_" + color + "_front.png";
    }).concat(["arena_floor.png"]);
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // Everything a spectator reads is the answer WORD, never "A".
  function answerWord(view, side) {
    if (side === "A") return view.optionA || "A";
    if (side === "B") return view.optionB || "B";
    return "—";
  }
  function sideColor(side) {
    return side === "A" ? SIDE_A : side === "B" ? SIDE_B : GHOST;
  }

  // ---- Layout --------------------------------------------------------------

  // The graph fills the top of the canvas; the belief tide takes a strip
  // along the bottom. Node size follows the spacing around the circle, so
  // the scene scales into whatever frame the viewer is embedded in.
  function computeLayout(width, height) {
    var margin = 8;
    var tideH = Math.max(52, Math.min(height * 0.19, 112));
    var graphTop = margin;
    var graphH = height - tideH - margin * 2;
    var cx = width / 2;
    var cy = graphTop + graphH * 0.5;
    var radius = Math.max(40, Math.min(width * 0.33, graphH * 0.40));
    var spacing = 2 * Math.PI * radius / SEATS;
    var size = Math.max(16, Math.min(58, spacing * 0.52));
    var scale = Math.max(0.55, Math.min(1.35, size / 44));
    var nodes = [];
    for (var i = 0; i < SEATS; i++) {
      var angle = -Math.PI / 2 + i * 2 * Math.PI / SEATS;
      nodes.push({
        x: cx + Math.cos(angle) * radius,
        y: cy + Math.sin(angle) * radius,
        angle: angle
      });
    }
    return {
      width: width, height: height, size: size, scale: scale,
      cx: cx, cy: cy, radius: radius, nodes: nodes,
      compact: width < COMPACT_W,
      graphTop: graphTop, graphH: graphH,
      tide: { x: margin, y: height - tideH - margin, w: width - 2 * margin,
        h: tideH }
    };
  }

  // ---- Drawing -------------------------------------------------------------

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var seats = view.seats || [];
    var now = view.now || Date.now();
    var L = computeLayout(w, h);
    var scale = L.scale;
    var fx = view.effects || {};
    var revealed = !!view.truth;

    // Floor.
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.45)";
    ctx.fillRect(0, 0, w, h);

    // Graph plate.
    ctx.save();
    ctx.fillStyle = STRIP;
    roundRect(ctx, 4, L.graphTop, w - 8, L.graphH, 10 * scale);
    ctx.fill();
    ctx.restore();

    // The question, across the top of the stage.
    drawQuestion(ctx, L, view, scale);

    // Edges first: the whole graph, from the first frame, so the spectator
    // sees the shape the cogs cannot.
    drawEdges(ctx, L, view, seats, revealed, scale);

    // Message pulses along the edges.
    drawPulses(ctx, L, view, fx, now, scale);

    // Nodes.
    for (var i = 0; i < SEATS; i++) {
      var seat = seats[i];
      if (!seat) continue;
      drawNode(ctx, images, L, i, seat, view, scale, {
        pending: seat.pending && !view.done,
        revealed: revealed,
        ballot: view.phase === "ballot",
        say: fx.lastSay ? fx.lastSay[i] : "",
        sayAt: fx.sayAt ? fx.sayAt[i] : null,
        now: now
      });
    }

    // The truth, stamped across the middle once the masks are off.
    if (revealed) {
      drawTruthStamp(ctx, L, view, scale);
    }

    // Belief tide.
    drawTide(ctx, L.tide, view, scale);
  }

  function drawQuestion(ctx, L, view, scale) {
    if (!view.question) return;
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    ctx.font = "600 " + Math.round(11 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    var line = view.question + "  " + answerWord(view, "A") + " ?  " +
      answerWord(view, "B") + " ?";
    ctx.fillText(ellipsize(ctx, line, L.width - 24), L.cx,
      L.graphTop + 4 * scale);
    ctx.restore();
  }

  // Chalk lines between neighbours. After the unmasking an edge touching a
  // saboteur is drawn in a dimmer hatch so the lie's reach is visible.
  function drawEdges(ctx, L, view, seats, revealed, scale) {
    var edges = view.edges || [];
    ctx.save();
    ctx.lineWidth = Math.max(1, 1.4 * scale);
    edges.forEach(function (edge) {
      var a = L.nodes[edge[0]];
      var b = L.nodes[edge[1]];
      if (!a || !b) return;
      var lying = revealed && seats[edge[0]] && seats[edge[1]] &&
        (seats[edge[0]].role === "saboteur" ||
          seats[edge[1]].role === "saboteur");
      ctx.strokeStyle = lying ? rgba(INK, 0.0) : CHALK;
      if (lying) {
        ctx.strokeStyle = "rgba(224, 82, 58, 0.30)";
        ctx.setLineDash([5 * scale, 4 * scale]);
      } else {
        ctx.setLineDash([]);
      }
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      ctx.lineTo(b.x, b.y);
      ctx.stroke();
    });
    ctx.setLineDash([]);
    ctx.restore();
  }

  // A travelling dot per (speaker, neighbour) pair, tinted by the claim and
  // sized by the confidence. This is the lie propagating, drawn.
  function drawPulses(ctx, L, view, fx, now, scale) {
    var pulses = view.pulses || [];
    ctx.save();
    pulses.forEach(function (pulse) {
      var a = L.nodes[pulse.from];
      var b = L.nodes[pulse.to];
      if (!a || !b) return;
      var at = fx.sayAt ? fx.sayAt[pulse.from] : null;
      var t = typeof at === "number" ?
        Math.min(1, (now - at) / SLIP_MS) : 1;
      var eased = 1 - Math.pow(1 - t, 2);
      var x = a.x + (b.x - a.x) * eased;
      var y = a.y + (b.y - a.y) * eased;
      var conf = typeof pulse.confidence === "number" ? pulse.confidence : 50;
      var r = (2.2 + 3.4 * conf / 100) * scale;
      ctx.globalAlpha = 0.55 + 0.45 * (1 - Math.abs(eased - 0.5) * 2);
      ctx.fillStyle = sideColor(pulse.claim);
      ctx.beginPath();
      ctx.arc(x, y, r, 0, Math.PI * 2);
      ctx.fill();
    });
    ctx.restore();
  }

  function drawNode(ctx, images, L, index, seat, view, scale, opts) {
    var node = L.nodes[index];
    var x = node.x;
    var y = node.y;
    var size = L.size;
    var color = seatColor(index);
    var sprite = images["soldier_" + color + "_front.png"];

    // Sprite.
    ctx.save();
    ctx.translate(x, y);
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, -size / 2, -size / 2, size, size);
    } else {
      ctx.fillStyle = COLOR_HEX[color];
      ctx.fillRect(-size / 3, -size / 3, size / 1.5, size / 1.5);
    }
    ctx.restore();

    // Acting halo while the table waits on this seat.
    if (opts.pending) {
      ctx.save();
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 2.5;
      ctx.setLineDash([5, 4]);
      ctx.beginPath();
      ctx.arc(x, y, size * 0.62, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    // The saboteur's mask badge, only after the unmasking.
    if (opts.revealed && seat.role === "saboteur") {
      drawMask(ctx, x + size * 0.42, y - size * 0.42, size * 0.26, scale);
    }

    // The clue coin — or, at the ballot, a sealed envelope; or, at the
    // tally, the opened vote.
    var coinX = x - size * 0.74;
    var coinY = y - size * 0.06;
    var coinR = Math.max(6, size * 0.26);
    if (opts.revealed) {
      drawBallotOpen(ctx, coinX, coinY, coinR, seat, view, scale);
    } else if (opts.ballot) {
      drawEnvelope(ctx, coinX, coinY, coinR, scale);
    } else {
      drawCoin(ctx, coinX, coinY, coinR, seat.clue, view, scale, L.compact);
    }

    // Name plate.
    var plate = seat.name || "";
    if (L.compact && plate.length > 6) plate = plate.slice(0, 6);
    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "alphabetic";
    ctx.font = "600 " + Math.round(12 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = COLOR_HEX[color];
    ctx.shadowColor = "rgba(0,0,0,0.85)";
    ctx.shadowBlur = 4;
    ctx.fillText(ellipsize(ctx, plate, size * 2.4), x,
      y + size * 0.60 + 11 * scale);
    ctx.restore();

    // Belief meter: filled from its centre toward red (A) or blue (B).
    drawBeliefMeter(ctx, x, y + size * 0.60 + 16 * scale, size * 1.5,
      Math.max(4, 5 * scale), seat.belief);

    // Speech bubble, pushed radially OUTWARD from the ring so ten of them
    // fan out instead of piling into the middle. Only recent speakers show
    // one (dropped entirely at embedded widths; the feed still carries
    // every message).
    if (opts.say && !L.compact) {
      var sayAge = typeof opts.sayAt === "number" ? opts.now - opts.sayAt :
        BUBBLE_HOLD_MS + 1;
      if (sayAge < BUBBLE_HOLD_MS) {
        var alpha = sayAge < BUBBLE_HOLD_MS * 0.6 ? 1 :
          Math.max(0.25, 1 - (sayAge - BUBBLE_HOLD_MS * 0.6) /
            (BUBBLE_HOLD_MS * 0.4));
        drawBubble(ctx, x, y, node.angle, size, opts.say,
          Math.min(200, L.radius * 0.85), scale, alpha);
      }
    }
  }

  function drawCoin(ctx, x, y, r, side, view, scale, compact) {
    ctx.save();
    ctx.beginPath();
    ctx.arc(x, y, r, 0, Math.PI * 2);
    ctx.fillStyle = sideColor(side);
    ctx.fill();
    ctx.lineWidth = 1.5;
    ctx.strokeStyle = "rgba(18, 13, 9, 0.7)";
    ctx.stroke();
    if (!compact) {
      ctx.font = "700 " + Math.round(9 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "top";
      ctx.fillStyle = PAPER;
      ctx.shadowColor = "rgba(0,0,0,0.9)";
      ctx.shadowBlur = 3;
      ctx.fillText(answerWord(view, side), x, y + r + 2 * scale);
    }
    ctx.restore();
  }

  function drawEnvelope(ctx, x, y, r, scale) {
    var w = r * 2.1;
    var h = r * 1.5;
    ctx.save();
    ctx.fillStyle = PAPER;
    ctx.strokeStyle = INK;
    ctx.lineWidth = 1.2;
    ctx.fillRect(x - w / 2, y - h / 2, w, h);
    ctx.strokeRect(x - w / 2, y - h / 2, w, h);
    ctx.beginPath();
    ctx.moveTo(x - w / 2, y - h / 2);
    ctx.lineTo(x, y + h * 0.14);
    ctx.lineTo(x + w / 2, y - h / 2);
    ctx.stroke();
    ctx.fillStyle = AMBER;
    ctx.beginPath();
    ctx.arc(x, y + h * 0.10, Math.max(2, r * 0.22), 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
  }

  function drawBallotOpen(ctx, x, y, r, seat, view, scale) {
    var vote = seat.vote;
    var w = r * 2.3;
    var h = r * 1.7;
    ctx.save();
    ctx.fillStyle = PAPER;
    ctx.fillRect(x - w / 2, y - h / 2, w, h);
    ctx.strokeStyle = sideColor(vote);
    ctx.lineWidth = 2;
    ctx.strokeRect(x - w / 2, y - h / 2, w, h);
    ctx.font = "700 " + Math.round(9 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillStyle = INK;
    ctx.fillText(ellipsize(ctx, answerWord(view, vote), w - 3), x, y);
    ctx.restore();
    if (seat.role === "honest" && vote) {
      var right = vote === view.truth;
      ctx.save();
      ctx.font = "700 " + Math.round(13 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillStyle = right ? "#45a85e" : "#e0523a";
      ctx.shadowColor = "rgba(0,0,0,0.9)";
      ctx.shadowBlur = 3;
      ctx.fillText(right ? "✓" : "✗", x, y - h * 0.9);
      ctx.restore();
    }
  }

  function drawMask(ctx, x, y, r, scale) {
    ctx.save();
    ctx.fillStyle = "#100b07";
    ctx.strokeStyle = PAPER;
    ctx.lineWidth = 1;
    roundRect(ctx, x - r, y - r * 0.62, r * 2, r * 1.24, r * 0.3);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = PAPER;
    ctx.beginPath();
    ctx.arc(x - r * 0.42, y, Math.max(1, r * 0.2), 0, Math.PI * 2);
    ctx.arc(x + r * 0.42, y, Math.max(1, r * 0.2), 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
  }

  function drawBeliefMeter(ctx, cx, y, w, h, belief) {
    var value = typeof belief === "number" ? belief : 50;
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.65)";
    ctx.fillRect(cx - w / 2, y, w, h);
    ctx.strokeStyle = "rgba(242, 232, 216, 0.18)";
    ctx.lineWidth = 1;
    ctx.strokeRect(cx - w / 2 + 0.5, y + 0.5, w - 1, h - 1);
    var half = w / 2;
    var span = Math.abs(value - 50) / 50 * half;
    if (value >= 50) {
      ctx.fillStyle = SIDE_A;
      ctx.fillRect(cx, y + 1, span, h - 2);
    } else {
      ctx.fillStyle = SIDE_B;
      ctx.fillRect(cx - span, y + 1, span, h - 2);
    }
    ctx.fillStyle = "rgba(242, 232, 216, 0.5)";
    ctx.fillRect(cx - 0.5, y, 1, h);
    ctx.restore();
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = text.split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  // Anchored at the node and pushed out along `angle` (the node's place on
  // the ring), with a tail pointing back at the speaker.
  function drawBubble(ctx, nx, ny, angle, size, text, maxW, scale, alpha) {
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font = Math.round(10 * scale) +
      "px -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif";
    var pad = 5 * scale;
    var lineH = 12 * scale;
    var lines = wrapLines(ctx, text, maxW - pad * 2, 2);
    var bw = 0;
    lines.forEach(function (l) { bw = Math.max(bw, ctx.measureText(l).width); });
    bw += pad * 2;
    var bh = lines.length * lineH + pad * 2 - 2;
    var reach = size * 0.62 + 6 * scale;
    var cx = nx + Math.cos(angle) * (reach + bw / 2);
    var cy = ny + Math.sin(angle) * (reach + bh / 2);
    var x = cx - bw / 2;
    var y = cy - bh / 2;
    ctx.shadowColor = "rgba(0,0,0,0.6)";
    ctx.shadowBlur = 5;
    ctx.fillStyle = PAPER;
    roundRect(ctx, x, y, bw, bh, 4 * scale);
    ctx.fill();
    ctx.shadowColor = "transparent";
    // Tail: a wedge from the bubble's edge back toward the node.
    var tx = nx + Math.cos(angle) * reach;
    var ty = ny + Math.sin(angle) * reach;
    ctx.beginPath();
    ctx.moveTo(tx, ty);
    ctx.lineTo(cx - Math.sin(angle) * 5 * scale,
      cy + Math.cos(angle) * 5 * scale);
    ctx.lineTo(cx + Math.sin(angle) * 5 * scale,
      cy - Math.cos(angle) * 5 * scale);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = INK;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    lines.forEach(function (l, i) {
      ctx.fillText(l, x + pad, y + pad + i * lineH);
    });
    ctx.restore();
  }

  function drawTruthStamp(ctx, L, view, scale) {
    ctx.save();
    ctx.translate(L.cx, L.cy);
    ctx.rotate(-0.06);
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = "700 " + Math.round(30 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = rgba(AMBER, 0.9);
    ctx.shadowColor = "rgba(0,0,0,0.85)";
    ctx.shadowBlur = 8;
    ctx.fillText(answerWord(view, view.truth), 0, -6 * scale);
    ctx.font = "600 " + Math.round(11 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.fillText("THE TRUTH · HONEST " + (view.honestCorrect || 0) + " / " +
      ((view.seats || []).filter(function (s) {
        return s.role === "honest";
      }).length), 0, 16 * scale);
    ctx.restore();
  }

  // The belief tide: ten lines, one per seat, y = belief, growing round by
  // round, with a centre rule at 50. Convergence, divergence, and the
  // moment a cluster flips are all visible at a glance.
  function drawTide(ctx, rect, view, scale) {
    var series = view.beliefs || [];
    var rounds = Math.max(view.rounds || 0, 2);
    var padL = 26 * scale;
    var padR = 30 * scale;
    var padT = 13 * scale;
    var padB = 8 * scale;
    var x0 = rect.x + padL;
    var x1 = rect.x + rect.w - padR;
    var y0 = rect.y + padT;
    var y1 = rect.y + rect.h - padB;
    var span = Math.max(1, rounds);

    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.55)";
    roundRect(ctx, rect.x, rect.y, rect.w, rect.h, 6 * scale);
    ctx.fill();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.12)";
    ctx.lineWidth = 1;
    ctx.stroke();

    ctx.font = "700 " + Math.round(9 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText("BELIEF TIDE", rect.x + 7 * scale, rect.y + 3 * scale);

    // Side labels and the 50/50 rule.
    ctx.textAlign = "right";
    ctx.textBaseline = "middle";
    ctx.font = "600 " + Math.round(8.5 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = SIDE_A;
    ctx.fillText(answerWord(view, "A").slice(0, 7), x0 - 3 * scale, y0 + 4);
    ctx.fillStyle = SIDE_B;
    ctx.fillText(answerWord(view, "B").slice(0, 7), x0 - 3 * scale, y1 - 4);
    ctx.strokeStyle = "rgba(242, 232, 216, 0.22)";
    ctx.setLineDash([3, 3]);
    ctx.beginPath();
    ctx.moveTo(x0, (y0 + y1) / 2);
    ctx.lineTo(x1, (y0 + y1) / 2);
    ctx.stroke();
    ctx.setLineDash([]);

    function px(i) { return x0 + (x1 - x0) * i / span; }
    function py(v) { return y1 - (y1 - y0) * v / 100; }

    for (var s = 0; s < SEATS; s++) {
      var line = series[s] || [];
      if (!line.length) continue;
      ctx.strokeStyle = COLOR_HEX[seatColor(s)];
      ctx.lineWidth = Math.max(1.2, 1.8 * scale);
      ctx.lineJoin = "round";
      ctx.globalAlpha = 0.9;
      ctx.beginPath();
      line.forEach(function (v, i) {
        var x = px(i);
        var y = py(v);
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      });
      ctx.stroke();
      var last = line.length - 1;
      ctx.fillStyle = COLOR_HEX[seatColor(s)];
      ctx.beginPath();
      ctx.arc(px(last), py(line[last]), 2.2 * scale, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
    ctx.restore();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  // `ctx` carries what a line needs from earlier events: the answer words
  // and the running belief picture.
  function describeEvent(event, nameMap, ctx) {
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    function word(side) {
      if (side === "A") return ctx.optionA;
      if (side === "B") return ctx.optionB;
      return "nothing";
    }
    switch (event.kind) {
      case "start":
        return "Ten cogs, one hidden fact — " + ctx.question + " " +
          ctx.optionA + " or " + ctx.optionB + "? Two or three of them are " +
          "paid to mislead.";
      case "round":
        return event.text === "sealed vote" ? "SEALED VOTE" :
          event.text === "final round" ? "Last round of talk." :
            "Messages travel one hop.";
      case "say":
        return name(event.seat) + (event.claim === "none" ?
          " says nothing in public" :
          " claims " + word(event.claim) + " (" + event.confidence + "%)");
      case "vote":
        return name(event.seat) + " votes " + word(event.vote) +
          (event.text ? " — \"" + nameMap.text(event.text) + "\"" : "");
      case "tally":
        var forA = (event.votes || []).filter(function (v) {
          return v === "A";
        }).length;
        var forB = (event.votes || []).filter(function (v) {
          return v === "B";
        }).length;
        return "TALLY: " + forA + " " + ctx.optionA + ", " + forB + " " +
          ctx.optionB;
      case "end":
        return event.text === "deadline" ?
          "Episode deadline — the vote was called early." :
          "Episode complete.";
      default: return JSON.stringify(event);
    }
  }

  function blockHead(block, rounds) {
    if (block < 0) return "SETUP";
    if (block >= rounds) return "SEALED VOTE";
    return "ROUND " + (block + 1);
  }

  // Renders the full transcript grouped into one section per round.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex, words) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var html = "";
    var lastBlock = null;
    var ctx = {
      optionA: (words && words.optionA) || "A",
      optionB: (words && words.optionB) || "B",
      question: (words && words.question) || "one hidden fact",
      rounds: (words && words.rounds) || 5
    };
    var lastNotes = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.round;
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' +
          blockHead(block, ctx.rounds) + "</div>";
        lastBlock = block;
      }
      var text = describeEvent(event, nameMap, ctx);
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "say" || event.kind === "vote" ?
          " seat" + (event.seat % COLORS.length) : "") +
        (event.kind === "tally" ? " feed-rwin" : "") +
        (i >= limit ? " feed-future" : "");
      html += '<div class="' + cls + '">' + escapeHtml(text) + "</div>";
      if (event.kind === "say" && event.text) {
        html += '<div class="feed-line feed-say' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " says: \"" +
            nameMap.text(event.text) + "\"") + "</div>";
      }
      if (event.kind === "tally") {
        var saboteurs = [];
        (event.roles || []).forEach(function (role, seat) {
          if (role === 1) saboteurs.push(clampName(nameMap.seat(seat)));
        });
        var honest = (event.roles || []).filter(function (r) {
          return r === 0;
        }).length;
        html += '<div class="feed-line feed-rwin' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml("THE TRUTH: " +
            (event.truth === "A" ? ctx.optionA : ctx.optionB) +
            ". Saboteurs: " + saboteurs.join(", ") + ". Honest cogs " +
            (event.honestCorrect || 0) + " of " + honest + " right.") +
          "</div>";
      }
      // Notes: dim, only when the seat's notes changed.
      if ((event.kind === "say" || event.kind === "vote") && event.notes &&
          event.notes !== lastNotes[event.seat]) {
        lastNotes[event.seat] = event.notes;
        html += '<div class="feed-line feed-notes' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " notes: " +
            nameMap.text(event.notes)) + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // when each seat last spoke (its pulses run and its bubble pops), what it
  // said, and when the round turned.
  function makeEffects() {
    var seen = 0;
    var roundAt = null;
    var sayAt = new Array(SEATS).fill(null);
    var lastSay = new Array(SEATS).fill("");
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only
      // the newest event gets to animate.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "round") {
            roundAt = animate ? now : null;
            sayAt = new Array(SEATS).fill(null);
            lastSay = new Array(SEATS).fill("");
          } else if (event.kind === "say") {
            sayAt[event.seat] = animate ? now : null;
            lastSay[event.seat] = event.text || "";
          }
        }
      },
      reset: function () {
        seen = 0;
        roundAt = null;
        sayAt = new Array(SEATS).fill(null);
        lastSay = new Array(SEATS).fill("");
      },
      view: function () {
        return { effects: { roundAt: roundAt, sayAt: sayAt.slice(),
          lastSay: lastSay.slice() } };
      }
    };
  }

  // ---- Scorebug, header, endscreen ----------------------------------------

  function matchHeader(state, config) {
    if (!state) return "";
    var parts = [];
    var rounds = state.rounds || (config && config.rounds) || 0;
    if (state.truth) {
      var forA = (state.votes || []).filter(function (v) {
        return v === "A";
      }).length;
      var forB = (state.votes || []).filter(function (v) {
        return v === "B";
      }).length;
      var honest = (state.seats || []).filter(function (s) {
        return s.role === "honest";
      }).length;
      parts.push("TRUTH — " + answerWord(state, state.truth));
      parts.push("HONEST " + (state.honestCorrect || 0) + "/" + honest);
      parts.push(forA + " " + answerWord(state, "A") + " · " + forB + " " +
        answerWord(state, "B"));
    } else if (state.phase === "ballot") {
      parts.push("SEALED VOTE");
      var waiting = (state.seats || []).filter(function (s) {
        return s.pending;
      });
      parts.push(waiting.length ? "WAITING ON " + waiting.length :
        "BALLOTS IN");
    } else {
      parts.push("ROUND " + ((state.round || 0) + 1) +
        (rounds ? " / " + rounds : ""));
      var open = (state.seats || []).filter(function (s) {
        return s.pending;
      });
      parts.push(open.length ? "WAITING ON " + open.length : "MESSAGES IN");
    }
    return parts.join(" · ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var revealed = !!state.truth;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      var belief = typeof seat.belief === "number" ? seat.belief : 50;
      var lean = belief >= 50 ? "A" : "B";
      html += '<div class="plate ' + seatColor(index) + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (seat.pending && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-belief" style="color:' + sideColor(lean) + '">' +
        (belief >= 50 ? belief : 100 - belief) + "%</span>" +
        (revealed ? '<span class="plate-score">' +
          (typeof seat.score === "number" ? seat.score.toFixed(1) : "0.0") +
          "</span>" : "") +
        '<span class="plate-label">' +
        (revealed && seat.role === "saboteur" ? "SABOTEUR" : "COG") +
        "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        return "episode deadline: the vote was called after " +
          (results.rounds || 0) + " of " +
          (results.maxRounds || results.rounds || 0) + " rounds";
      default: return "";
    }
  }

  // Final standings overlay: verdict up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var roles = results.roles || [];
    var votes = results.votes || [];
    var clues = results.clues || [];
    var truth = results.truth;
    var optionA = results.optionA || "A";
    var optionB = results.optionB || "B";
    function word(side) {
      return side === "A" ? optionA : side === "B" ? optionB : "—";
    }
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) { return (scores[b] || 0) - (scores[a] || 0); });
    var saboteurs = [];
    roles.forEach(function (role, i) {
      if (role === "Saboteur") saboteurs.push(names[i]);
    });
    var honestSeats = results.honestSeats || 0;
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">THE TRUTH WAS ' + escapeHtml(word(truth)) +
      "</div>" +
      '<div class="end-verdict">HONEST COGS ' +
      (results.honestCorrect || 0) + " / " + honestSeats + "</div>" +
      '<div class="end-reason">saboteurs: ' +
      escapeHtml(saboteurs.join(", ") || "none") +
      (reason ? " · " + escapeHtml(reason) : "") + "</div>" +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">role</span>' +
      '<span class="end-head">clue</span>' +
      '<span class="end-head">vote</span>' +
      '<span class="end-head"></span>' +
      '<span class="end-head">score</span>';
    order.forEach(function (i, rank) {
      var leader = rank === 0;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      var right = votes[i] === truth;
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell(escapeHtml(roles[i] || "")) +
        cell(escapeHtml(word(clues[i]))) +
        cell(escapeHtml(word(votes[i]))) +
        cell(roles[i] === "Honest" ? (right ? "✓" : "✗") : "·") +
        cell(((scores || [])[i] || 0).toFixed(1));
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.edges = state.edges || [];
    view.pulses = state.pulses || [];
    view.beliefs = state.beliefs || [];
    view.votes = state.votes || [];
    view.question = state.question || "";
    view.optionA = state.optionA || "A";
    view.optionB = state.optionB || "B";
    view.truth = state.truth || "";
    view.verdict = state.verdict || "";
    view.honestCorrect = state.honestCorrect;
    view.round = state.round || 0;
    view.rounds = state.rounds || 0;
    view.roundsPlayed = state.roundsPlayed || 0;
    view.phase = state.phase || "";
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  // A redacted player frame becomes a ten-seat state with the own seat
  // filled in so the same scene draws.
  function playerFrameToState(data) {
    if (data.seats) return data;
    var seats = [];
    for (var i = 0; i < SEATS; i++) {
      seats.push({ name: "Cog " + (i + 1), seat: i, clue: "", claim: "none",
        confidence: 50, belief: 50, message: "", role: "cog", vote: null,
        voteReason: "", notes: "", score: 0, pending: false,
        neighbours: [], degree: 0 });
    }
    if (typeof data.slot === "number" && seats[data.slot]) {
      seats[data.slot].name = data.name || seats[data.slot].name;
      seats[data.slot].notes = data.notes || "";
      seats[data.slot].degree = data.degree || 0;
    }
    return {
      seats: seats, edges: [], pulses: [], beliefs: [], votes: [],
      question: data.question || "", optionA: data.optionA || "A",
      optionB: data.optionB || "B", truth: "", verdict: "",
      round: data.round, rounds: data.rounds, roundsPlayed: data.round || 0,
      phase: data.phase || "talk", gameDone: data.done,
      reason: data.reason, events: []
    };
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = playerFrameToState(data);
            if (latest) {
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined, latest);
              }
              if (options.clock) {
                options.clock.textContent = matchHeader(latest, latest);
              }
              updateScorebug(options.scorebug, latest, nameMap);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          });
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per round, a marker
  // per message (coloured by the seat), per vote, and the tally (taller).
  function buildScrub(container, events, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.round;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      var kind = event.kind;
      if (kind !== "say" && kind !== "vote" && kind !== "tally") return;
      var marker = document.createElement("div");
      marker.className = "beat-marker" +
        (kind === "say" || kind === "vote" ?
          " seat" + (event.seat % COLORS.length) : "") +
        (kind === "vote" ? " vote" : "") +
        (kind === "tally" ? " death" : "");
      marker.style.left = ((i + 1) / events.length * 100) + "%";
      container.appendChild(marker);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var results = payload.results || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], phase: "", round: 0 };
      }

      function words() {
        var state = currentState();
        return {
          optionA: state.optionA || results.optionA || "A",
          optionB: state.optionB || results.optionB || "B",
          question: state.question || results.question || "one hidden fact",
          rounds: state.rounds || config.rounds || 5
        };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) {
          renderFeed(options.feed, events, nameMap, index, words());
        }
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent = matchHeader(currentState(), config);
        }
        updateScorebug(options.scorebug, currentState(), nameMap);
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at: a round turn
        // gets read, a message less so, a message with text a little
        // longer, the tally longest.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = shown && shown.kind === "round" ? 1500 :
          shown && shown.kind === "say" ? (shown.text ? 900 : 450) :
          shown && shown.kind === "vote" ? 600 :
          shown && (shown.kind === "tally" || shown.kind === "end") ? 1500 :
          600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        });
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.RumorRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();
