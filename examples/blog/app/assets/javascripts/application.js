// Rails-UJS-lite: any element with a data-confirm attribute (button_to
// destroy links generate one, see app/views/posts/_post.erb) pops a native
// confirm() dialog before its click is allowed to reach the form submit;
// cancelling the dialog cancels the click.
document.addEventListener("click", function (event) {
  var target = event.target.closest("[data-confirm]");
  if (!target) return;
  if (!window.confirm(target.getAttribute("data-confirm"))) {
    event.preventDefault();
    event.stopPropagation();
  }
});
