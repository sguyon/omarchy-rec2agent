// Draw the keyboard: each key is [width in key units, style].
const rows = [
  [...Array(13).fill([1, ""]), [2, "m"]],
  [[1.5, "m"], ...Array(12).fill([1, ""]), [1.5, "m"]],
  [[1.75, "m"], ...Array(11).fill([1, ""]), [2.25, "a"]],
  [[2.25, "m"], ...Array(10).fill([1, ""]), [1.75, "m"]],
  [[1.25, "m"], [1.25, "m"], [1.25, "m"], [6.25, ""], [1, "m"], [1, "m"], [1, "m"]],
];
document.getElementById("kb").innerHTML = rows.map(r => '<div class="row">' + r.map(([w, c]) => `<i class="${c}" style="flex:${w}"></i>`).join("") + "</div>").join("");
