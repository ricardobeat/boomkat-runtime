default:
    @just --list

# Publish web/ to https://tomasi.studio/boomkat-runtime/ (goes live immediately)
publish-site:
    rm -rf .site && mkdir -p .site/boomkat-runtime
    cp web/index.html .site/boomkat-runtime/
    scripts/publish-site.sh boomkat-runtime boomkat-runtime .site
    rm -rf .site

# Roll https://tomasi.studio/boomkat-runtime/ back to the previous deploy
rollback-site:
    bunny sites deployments publish --previous --force --site boomkat-runtime
    scripts/publish-site.sh boomkat-runtime boomkat-runtime
