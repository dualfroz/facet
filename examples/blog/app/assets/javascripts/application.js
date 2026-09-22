document.addEventListener("click", function (event) {
  var target = event.target.closest("[data-confirm]");
  if (!target) return;
  if (!window.confirm(target.getAttribute("data-confirm"))) {
    event.preventDefault();
    event.stopPropagation();
  }
});
