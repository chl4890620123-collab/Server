FROM nginx:1.30.7-alpine

COPY nginx/nginx.conf /etc/nginx/conf.d/default.conf
COPY public/ /usr/share/nginx/html/

EXPOSE 80
