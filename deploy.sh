#!/usr/bin/env sh

# abort on errors
set -e

# rm -rf dist
# mkdir dist

# build
npm run build

# navigate into the build output directory
cd dist
ls
# place .nojekyll to bypass Jekyll processing
echo > .nojekyll

# if you are deploying to a custom domain
# echo 'www.example.com' > CNAME

git init
git checkout -B main
git add -A
git commit -m 'deploy'

# if you are deploying to https://<USERNAME>.github.io
# git push -f git@github.com:<USERNAME>/<USERNAME>.github.io.git main
#
# if you are deploying to https://<USERNAME>.github.io/<REPO>

echo "Pushing..."
git remote add origin https://github.com/textchimp/looper.git
# git push -f git@github.com:textchimp/looper.git main:gh-pages
git push -f origin main:gh-pages

cd -