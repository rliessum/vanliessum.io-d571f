(function () {
  if (localStorage.getItem('theme') === 'light') {
    document.documentElement.classList.remove('dark');
  }

  function init() {
    var toggle = document.getElementById('theme-toggle');
    var sunIcon = document.getElementById('sun-icon');
    var moonIcon = document.getElementById('moon-icon');
    if (!toggle || !sunIcon || !moonIcon) return;

    function updateIcons() {
      var isDark = document.documentElement.classList.contains('dark');
      sunIcon.classList.toggle('hidden', isDark);
      moonIcon.classList.toggle('hidden', !isDark);
    }

    updateIcons();

    toggle.addEventListener('click', function () {
      var isDark = document.documentElement.classList.contains('dark');
      if (isDark) {
        document.documentElement.classList.remove('dark');
        localStorage.setItem('theme', 'light');
      } else {
        document.documentElement.classList.add('dark');
        localStorage.setItem('theme', 'dark');
      }
      updateIcons();
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
