# Dabboos Sales Command Center — container image.
# Builds a small Node.js image that serves the static dashboard.
FROM node:20-alpine

WORKDIR /app

# Install only production deps first (better layer caching).
COPY package*.json ./
RUN npm install --omit=dev

# Copy the rest of the app.
COPY . .

# The server reads PORT (default 3000). Override at run time if needed.
ENV PORT=3000
EXPOSE 3000

CMD ["npm", "start"]
