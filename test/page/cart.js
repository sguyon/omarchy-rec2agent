const $ = id => document.getElementById(id);
let cart = [], touched = false, lost = false;
const serverCopy = [];

function render() {
  $("count").textContent = cart.length;
  $("count").classList.toggle("bad", lost);
  if (touched) document.title = "(" + cart.length + ") Tactile 75 | keycap.co";   // like real shops; tests read it from the window title
  $("count").classList.remove("pop"); void $("count").offsetWidth; $("count").classList.add("pop");
  $("dbody").classList.toggle("lost", lost && !cart.length);
  $("dtitle").textContent = cart.length ? "Your cart (" + cart.length + ")" : "Your cart";
  $("dbody").innerHTML = cart.length
    ? '<div class="line"><div class="ph"></div><div><b>Tactile 75</b><small>Tactile switches · Graphite</small><br><small>Qty 1</small></div><div class="p">$89.00</div></div>'
    : (lost ? '<div class="alert"><div class="top"><div class="bang">!</div><div><b>Couldn\'t update your cart</b><small>Something went wrong. Your item was removed.</small></div></div><div class="gone"><div class="ph"></div><div><b>Tactile 75</b><small>$89.00</small></div><span class="tag">Removed</span></div><div class="retry">Try again</div></div>' : '') + '<div class="empty' + (lost ? ' after' : '') + '"><div class="ic">🛒</div><b>Your cart is empty</b>Add something and it will show up here.</div>';
  $("dfoot").innerHTML = cart.length
    ? '<div class="sub"><span>Subtotal</span><span>$89.00</span></div><button>Checkout</button>'
    : (lost ? '<div class="sub"><span>Subtotal</span><span>$0.00</span></div><button disabled>Checkout</button>' : '<button>Continue shopping</button>');
}

$("add").onclick = () => {
  touched = true;
  cart.push("Tactile 75");
  render();
  document.body.classList.add("open");   // the drawer slides in with the item
  setTimeout(syncCart, 1200);
};
$("close").onclick = $("veil").onclick = () => document.body.classList.remove("open");

function syncCart() {
  // sync the cart with the server
  cart = [...serverCopy];
  lost = true;
  render();
}
render();

// Open index.html#auto, then press G: it clicks "Add to cart" by itself.
if (location.hash === "#auto") addEventListener("keydown", e => { if (e.key === "g") $("add").click(); });
